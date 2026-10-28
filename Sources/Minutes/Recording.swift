import AVFoundation
import CoreAudio
import Foundation

/// One meeting: the Mac's microphone goes to me.wav, everything the Mac plays goes to others.wav,
/// and the meeting window goes to screen.mov. Files are written in staging and moved into the workspace afterwards.
final class Recording {
    let id = UUID().uuidString
    let appName: String?
    let bundleID: String?
    let title: String
    let autoStop: Bool
    let startedAt = Date()
    let folder: URL
    private(set) var audioStartedAt: Date?
    private(set) var screenError: Error?

    private let systemAudio = SystemAudioTap()
    private let microphone = MicCapture()
    private let screen: ScreenRecorder?
    private var screenTask: Task<Void, Never>?

    var micURL: URL { folder.appendingPathComponent("me.wav") }
    var systemURL: URL { folder.appendingPathComponent("others.wav") }
    var screenURL: URL { folder.appendingPathComponent("screen.mov") }

    init(appName: String?, bundleID: String?, title: String, autoStop: Bool, recordScreen: Bool) throws {
        self.appName = appName
        self.bundleID = bundleID
        self.title = Workspace.cleanTitle(title)
        self.autoStop = autoStop
        screen = recordScreen ? ScreenRecorder() : nil
        folder = Workspace.staging.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Workspace.writeMeta(
            MeetingMeta(id: id, title: self.title, startedAt: startedAt, app: appName, bundleID: bundleID), to: folder)
    }

    func start() throws {
        do {
            try microphone.start(writingTo: micURL)
            try systemAudio.start(writingTo: systemURL)
            audioStartedAt = Date()
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

/// Writes any incoming PCM as 16 kHz mono 16-bit WAV, the input whisper.cpp expects.
final class TrackWriter {
    private var file: AVAudioFile?
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    init(url: URL) throws {
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

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, buffer.frameLength > 0 else { return }
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
        if output.frameLength > 0 { try? file.write(from: output) }
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

final class MicCapture {
    private let engine = AVAudioEngine()
    private var writer: TrackWriter?
    private var configObserver: NSObjectProtocol?

    func start(writingTo url: URL) throws {
        writer = try TrackWriter(url: url)
        try startEngine()
        // Switching headsets stops the engine; pick up the new input and keep going.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            try? self?.startEngine()
        }
    }

    private func startEngine() throws {
        guard let writer else { return }
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "Minutes", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available or microphone access denied"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in writer.write(buffer) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
    }
}

/// Captures all system output through a Core Audio process tap (macOS 14.2+).
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private let queue = DispatchQueue(label: "minutes.system-audio", qos: .userInitiated)

    func start(writingTo url: URL) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
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
        let writer = try TrackWriter(url: url)
        self.writer = writer
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            // An output device with its own mic adds input streams ahead of the tap's; keep the tap's.
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard all.count >= tapBuffers else { return }
            if all.count == tapBuffers {
                if let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) { writer.write(pcm) }
                return
            }
            let list = AudioBufferList.allocate(maximumBuffers: tapBuffers)
            defer { free(list.unsafeMutablePointer) }
            for i in 0..<tapBuffers { list[i] = all[all.count - tapBuffers + i] }
            if let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil) { writer.write(pcm) }
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
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
