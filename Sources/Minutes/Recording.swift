import AVFoundation
import CoreAudio
import Foundation

/// One meeting: the Mac's microphone goes to me.wav, everything the Mac plays goes to others.wav,
/// and, for a call, the meeting window goes to screen.mov. Files are written in staging and moved into the workspace
/// afterwards.
final class Recording {
    let id: String
    let appName: String?
    let bundleID: String?
    private(set) var title: String
    let autoStop: Bool
    let mode: RecordMode
    let startedAt = Date()
    let folder: URL
    private(set) var audioStartedAt: Date?
    private(set) var screenError: Error?

    private let microphone: TrackCapture
    private let systemAudio: TrackCapture
    private let screen: ScreenRecorder?
    private var screenTask: Task<Void, Never>?

    /// Recent loudness of each track, 0…1, for the live meters.
    var levels: (me: Float, others: Float) { (microphone.meter.level, systemAudio.meter.level) }

    /// The mic track records silence while on, as for talk aside while muted on the call.
    var micMuted: Bool {
        get { (microphone as? MicCapture)?.muted ?? false }
        set { (microphone as? MicCapture)?.muted = newValue }
    }

    var micURL: URL { folder.appendingPathComponent("me.wav") }
    var systemURL: URL { folder.appendingPathComponent("others.wav") }
    var screenURL: URL { folder.appendingPathComponent("screen.mov") }

    /// `note`: the recording goes into that note once finished; it keeps the note's id and title. The start is the
    /// recording's, as for any meeting, so the duration, the transcript header and the summary date are the call's.
    init(
        appName: String?, bundleID: String?, title: String, attendees: [String]? = nil, autoStop: Bool, mode: RecordMode,
        note: MeetingMeta? = nil, staging: URL = Workspace.staging,
        tracks: (mic: TrackCapture, system: TrackCapture) = (MicCapture(), SystemAudioTap())
    ) throws {
        id = note?.id ?? UUID().uuidString
        self.appName = appName
        self.bundleID = bundleID
        self.title = Workspace.cleanTitle(note?.title ?? title)
        self.autoStop = autoStop
        self.mode = mode
        (microphone, systemAudio) = tracks
        screen = mode.recordsScreen ? ScreenRecorder() : nil
        folder = staging.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Workspace.writeMeta(
            MeetingMeta(
                id: id, title: self.title, startedAt: startedAt, app: appName, bundleID: bundleID, mode: mode,
                attendees: attendees?.isEmpty == false ? attendees : nil, note: note == nil ? nil : true),
            to: folder)
    }

    var recordsScreen: Bool { screen != nil }

    /// Names the recording while it runs, after a calendar event (its invitees, confidential when someone is external
    /// and Settings say so) or not. `confidential` nil leaves the flag as it is.
    func retitle(_ title: String, attendees: [String]?, confidential: Bool?) throws {
        let clean = Workspace.cleanTitle(title)
        _ = try Workspace.updateMeta(folder) {
            $0.title = clean
            $0.attendees = attendees?.isEmpty == false ? attendees : nil
            if let confidential { $0.confidential = confidential ? true : nil }
        }
        self.title = clean
    }

    func start() throws {
        // Both tracks are placed on this clock: the system tap takes seconds to set up, and an unaligned others.wav
        // plays the call twice once the mic has picked it up from the speakers.
        let origin = AudioGetCurrentHostTime()
        audioStartedAt = Date()
        do {
            try microphone.start(writingTo: micURL, origin: origin)
            try systemAudio.start(writingTo: systemURL, origin: origin)
        } catch {
            stopAudio()
            throw error
        }
        guard let screen else { return }
        let bundleID = bundleID, url = screenURL
        screenTask = Task { [weak self] in
            do {
                try await screen.start(bundleID: bundleID, writingTo: url)
            } catch {
                self?.screenError = error
            }
        }
    }

    func stopAudio() {
        microphone.stop()
        systemAudio.stop()
    }

    /// Stops every track and records the end time and video offset; the screen file needs a moment to finish.
    func stop() async {
        stopAudio()
        let endedAt = Date()
        await screenTask?.value
        await screen?.stop()
        var offset: TimeInterval?
        if let video = screen?.firstFrameAt, let audio = audioStartedAt { offset = video.timeIntervalSince(audio) }
        _ = try? Workspace.updateMeta(folder) {
            $0.endedAt = endedAt
            $0.videoOffset = offset
        }
    }
}

/// Loudness of the last ~100 ms of a track for a live meter: RMS in dBFS mapped from −60…0 to 0…1, rising at once
/// and falling smoothly.
final class LevelMeter: @unchecked Sendable {
    static let window: TimeInterval = 0.1
    // Per second, in meter units: a full-scale reading falls to zero in about 0.7 s.
    static let fallRate: Float = 1.5

    private let lock = NSLock()
    private var chunks: [(time: TimeInterval, squares: Double, count: Int)] = []
    private var shown: Float = 0
    private var shownAt: TimeInterval = 0

    /// 16-bit samples just written; `now` is a monotonic clock in seconds.
    func add(_ samples: UnsafeBufferPointer<Int16>, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !samples.isEmpty else { return }
        var squares = 0.0
        for sample in samples {
            let value = Double(sample) / 32_768
            squares += value * value
        }
        lock.withLock {
            chunks.append((now, squares, samples.count))
            chunks.removeAll { now - $0.time > Self.window }
        }
    }

    var level: Float { level(now: ProcessInfo.processInfo.systemUptime) }

    func level(now: TimeInterval) -> Float {
        lock.withLock {
            chunks.removeAll { now - $0.time > Self.window }
            let count = chunks.reduce(0) { $0 + $1.count }
            let rms = count > 0 ? (chunks.reduce(0) { $0 + $1.squares } / Double(count)).squareRoot() : 0
            let target = Self.scale(rms)
            let fallen = max(0, shown - Self.fallRate * Float(max(0, now - shownAt)))
            shown = max(target, fallen)
            shownAt = now
            return shown
        }
    }

    func reset() {
        lock.withLock {
            chunks = []
            shown = 0
        }
    }

    static func scale(_ rms: Double) -> Float {
        guard rms > 0 else { return 0 }
        let dB = 20 * log10(rms)
        return Float(min(max((dB + 60) / 60, 0), 1))
    }
}

/// Writes any incoming PCM as 16 kHz mono 16-bit WAV, the input whisper.cpp expects.
final class TrackWriter {
    let meter: LevelMeter
    private var file: AVAudioFile?
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private let origin: UInt64?
    private var written: AVAudioFramePosition = 0
    // Gaps shorter than this are capture jitter, not missing audio.
    private let maxGap: AVAudioFramePosition = 1_600

    /// With `origin` (a host time), each buffer lands where its own host time says, padded with silence before it.
    init(url: URL, origin: UInt64? = nil, meter: LevelMeter = LevelMeter()) throws {
        self.origin = origin
        self.meter = meter
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        self.file = file
        outputFormat = file.processingFormat
    }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, buffer.frameLength > 0 else { return }
        if let origin, let hostTime, hostTime > origin {
            let seconds = Double(AudioConvertHostTimeToNanos(hostTime - origin)) / 1e9
            let gap = AVAudioFramePosition(seconds * outputFormat.sampleRate) - written
            if gap > maxGap, let silence = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(gap)) {
                silence.frameLength = AVAudioFrameCount(gap)
                if let channel = silence.int16ChannelData { channel[0].update(repeating: 0, count: Int(gap)) }
                if (try? file.write(from: silence)) != nil { written += gap }
            }
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.downmix = true
        }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if output.frameLength > 0, (try? file.write(from: output)) != nil {
            written += AVAudioFramePosition(output.frameLength)
            if let samples = output.int16ChannelData?[0] {
                meter.add(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            }
        }
    }

    func close() {
        lock.lock()
        file = nil // AVAudioFile finalises the WAV header on deinit
        lock.unlock()
    }

    /// A crash leaves the RIFF and data sizes as they were before the first flush; set them from the file size.
    static func repairHeader(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 12, size <= UInt64(UInt32.max) else { return }
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: count)
        }
        func write(_ value: UInt32, at offset: UInt64) {
            try? handle.seek(toOffset: offset)
            try? handle.write(contentsOf: withUnsafeBytes(of: value.littleEndian) { Data($0) })
        }
        guard read(0, 4) == Data("RIFF".utf8), read(8, 4) == Data("WAVE".utf8) else { return }
        var offset: UInt64 = 12
        while offset + 8 <= size, let chunk = read(offset, 8), chunk.count == 8 {
            let length = UInt64(chunk.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            if chunk.prefix(4) == Data("data".utf8) {
                write(UInt32((size - offset - 8) & ~1), at: offset + 4)
                write(UInt32(size - 8), at: 4)
                return
            }
            offset += 8 + length + (length & 1)
        }
    }
}

/// A source that writes one WAV track and meters it.
protocol TrackCapture: AnyObject {
    var meter: LevelMeter { get }
    func start(writingTo url: URL, origin: UInt64) throws
    func stop()
}

final class MicCapture: TrackCapture {
    let meter = LevelMeter()
    private let engine = AVAudioEngine()
    private var writer: TrackWriter?
    private var configObserver: NSObjectProtocol?
    private var outputWatch: OutputWatch?
    private let muteLock = NSLock()
    private var isMuted = false

    /// Buffers are dropped while on; the writer pads the gap with silence from host time, so the track stays aligned.
    var muted: Bool {
        get { muteLock.withLock { isMuted } }
        set { muteLock.withLock { isMuted = newValue } }
    }

    func start(writingTo url: URL, origin: UInt64) throws {
        writer = try TrackWriter(url: url, origin: origin, meter: meter)
        try startEngine()
        // Switching headsets stops the engine; pick up the new input and keep going.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            try? self?.startEngine()
        }
        outputWatch = OutputWatch { [weak self] in
            guard let self, self.writer != nil, OutputWatch.speakers() != self.engine.inputNode.isVoiceProcessingEnabled else { return }
            try? self.startEngine()
        }
    }

    private func startEngine() throws {
        guard let writer else { return }
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // On loudspeakers the raw mic records the call a second time; voice processing cancels it. It also ducks
        // every other app and changes the sound of the call, so headphones get the raw mic. If it cannot be switched
        // on, the raw mic is still better than nothing.
        let speakers = OutputWatch.speakers()
        if input.isVoiceProcessingEnabled != speakers, (try? input.setVoiceProcessingEnabled(speakers)) != nil, speakers {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let processed = input.isVoiceProcessingEnabled
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "Minutes", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available or microphone access denied"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            if self?.muted == true { return }
            writer.write(processed ? Self.firstChannel(buffer) : buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil)
        }
        engine.prepare()
        try engine.start()
    }

    // Voice processing hands over the same cleaned signal on every channel (nine on a MacBook); keep one.
    private static func firstChannel(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.channelCount > 1, !buffer.format.isInterleaved,
              let mono = AVAudioFormat(
                  commonFormat: buffer.format.commonFormat, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = copy.floatChannelData
        else { return buffer }
        copy.frameLength = buffer.frameLength
        target[0].update(from: source[0], count: Int(buffer.frameLength))
        return copy
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        outputWatch = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
        meter.reset()
    }
}

/// Whether the call is heard through loudspeakers, and a callback when the output device or its jack changes.
final class OutputWatch {
    private let onChange: () -> Void
    private let queue = DispatchQueue.main
    private var watched: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var listener: AudioObjectPropertyListenerBlock = { _, _ in }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        listener = { [weak self] _, _ in
            self?.rewatch()
            self?.onChange()
        }
        rewatch()
    }

    deinit { unwatch() }

    /// MacBook, display and AirPlay speakers; headphones on the jack, Bluetooth, USB headsets and virtual devices are not.
    static func speakers() -> Bool {
        guard let device = try? CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)),
              device != kAudioObjectUnknown,
              let transport = try? CA.get(device, kAudioDevicePropertyTransportType, initial: UInt32(0))
        else { return true }
        switch transport {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            if let source = dataSource(device) { return source == fourCC("ispk") }
            return !(CA.string(device, kAudioObjectPropertyName) ?? "").localizedCaseInsensitiveContains("headphone")
        default:
            return false
        }
    }

    private static func dataSource(_ device: AudioObjectID) -> UInt32? {
        var address = sourceAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static let sourceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private static func fourCC(_ code: String) -> UInt32 { code.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func rewatch() {
        unwatch()
        var targets = [(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice))]
        if let device = try? CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)),
           device != kAudioObjectUnknown {
            targets.append((device, Self.sourceAddress))
        }
        for (object, address) in targets {
            var address = address
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, listener) == noErr { watched.append((object, address)) }
        }
    }

    private func unwatch() {
        for (object, address) in watched {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        watched = []
    }
}

/// Captures all system output through a Core Audio process tap (macOS 14.2+).
final class SystemAudioTap: TrackCapture {
    let meter = LevelMeter()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private let queue = DispatchQueue(label: "minutes.system-audio", qos: .userInitiated)

    func start(writingTo url: URL, origin: UInt64) throws {
        // Minutes' own sound (a briefing, a voice preview) stays out of the Others track.
        let own = CA.processObject(pid: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the system audio tap")

        let outputID = try CA.get(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID(0))
        guard let outputUID = CA.string(outputID, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(status: -1, action: "find the output device")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Minutes system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the capture device")

        var streamFormat = try CA.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &streamFormat) else {
            throw CoreAudioError(status: -1, action: "read the tap format")
        }
        let writer = try TrackWriter(url: url, origin: origin, meter: meter)
        self.writer = writer
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, inputTime, _, _ in
            let stamp = inputTime.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : nil
            // An output device with its own mic adds input streams ahead of the tap's; keep the tap's.
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard all.count >= tapBuffers else { return }
            if all.count == tapBuffers {
                if let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) { writer.write(pcm, hostTime: hostTime) }
                return
            }
            let list = AudioBufferList.allocate(maximumBuffers: tapBuffers)
            defer { free(list.unsafeMutablePointer) }
            for i in 0..<tapBuffers { list[i] = all[all.count - tapBuffers + i] }
            if let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil) { writer.write(pcm, hostTime: hostTime) }
        }, "attach to the capture device")
        try check(AudioDeviceStart(aggregateID, procID), "start system audio capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        queue.sync {}
        writer?.close()
        writer = nil
        meter.reset()
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
