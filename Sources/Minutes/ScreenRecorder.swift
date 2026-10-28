import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ScreenRecorderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static let permission = ScreenRecorderError(
        message: "Screen Recording permission is off: System Settings > Privacy & Security > Screen & System Audio Recording")
}

/// Records the meeting app's largest window (or the main display) to an HEVC .mov with ScreenCaptureKit.
final class ScreenRecorder {
    /// Wall-clock time of the first frame written; the muxer aligns video to audio from it.
    private(set) var firstFrameAt: Date?

    // Only touched inside `chain`, so start and stop never interleave.
    private var sink: StreamSink?
    private let chain = OperationChain()

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    func start(bundleID: String?, writingTo url: URL) async throws {
        try await chain.run { try await self.begin(bundleID: bundleID, url: url) }
    }

    // A stop() during start() waits for the stream start() installs and stops it; overlapping stops all wait for the file.
    func stop() async {
        try? await chain.run { await self.end() }
    }

    private func begin(bundleID: String?, url: URL) async throws {
        await end()
        firstFrameAt = nil
        guard Self.hasPermission() else { throw ScreenRecorderError.permission }

        let filter: SCContentFilter
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            filter = try await Self.filter(for: bundleID, in: content)
        } catch {
            throw Self.mapped(error)
        }
        let config = Self.configuration(for: filter)
        let writer = try VideoFileWriter(url: url, width: config.width, height: config.height)
        let sink = StreamSink(writer: writer)
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        sink.stream = stream
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: writer.queue)
            try await stream.startCapture()
        } catch {
            await writer.close()
            throw Self.mapped(error)
        }
        self.sink = sink
    }

    private func end() async {
        guard let sink else { return }
        self.sink = nil
        // Throws when the stream already stopped on its own; the writer still has to finish.
        try? await sink.stream?.stopCapture()
        await sink.writer.close()
        firstFrameAt = sink.writer.queue.sync { sink.writer.firstFrameAt }
        sink.stream = nil
    }

    private static func mapped(_ error: Error) -> Error {
        if (error as NSError).domain == SCStreamErrorDomain, (error as NSError).code == SCStreamError.userDeclined.rawValue {
            return ScreenRecorderError.permission
        }
        return error
    }

    // Core Audio reports helper processes (com.google.Chrome.helper), so match on bundle prefix both ways.
    private static func matches(_ owner: String?, _ bundleID: String) -> Bool {
        guard let owner, !owner.isEmpty else { return false }
        return owner == bundleID || bundleID.hasPrefix(owner + ".") || owner.hasPrefix(bundleID + ".")
    }

    private static func filter(for bundleID: String?, in content: SCShareableContent) async throws -> SCContentFilter {
        if let bundleID {
            let window = content.windows
                .filter {
                    $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 320 && $0.frame.height >= 200
                        && matches($0.owningApplication?.bundleIdentifier, bundleID)
                }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            if let window { return SCContentFilter(desktopIndependentWindow: window) }
        }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ScreenRecorderError(message: "No display to record")
        }
        // Minutes may have no window on screen now and open one mid-call; the on-screen list can then miss it.
        let pid = ProcessInfo.processInfo.processIdentifier
        let all = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let own = all.applications.filter { $0.processID == pid }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }

    private static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let scale = CGFloat(filter.pointPixelScale)
        var width = filter.contentRect.width * scale
        var height = filter.contentRect.height * scale
        let longest = max(width, height)
        if longest > 1920 {
            width *= 1920 / longest
            height *= 1920 / longest
        }
        let config = SCStreamConfiguration()
        config.width = max(2, Int(width) & ~1)
        config.height = max(2, Int(height) & ~1)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = false
        // The window may be resized mid-call; keep the output size and letterbox.
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.queueDepth = 6
        return config
    }
}

private final class StreamSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: VideoFileWriter
    var stream: SCStream?

    init(writer: VideoFileWriter) {
        self.writer = writer
    }

    // Runs on writer.queue.
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, Self.isComplete(sample) else { return }
        writer.append(sample)
    }

    // The window closed or capture broke: keep what was captured.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        writer.queue.async { [writer] in writer.finish() }
    }

    // ScreenCaptureKit also delivers idle and blank frames without new pixels.
    static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sample) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int
        else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }
}

/// Runs async operations one at a time, in call order.
private final class OperationChain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Error>?

    func run(_ operation: @escaping () async throws -> Void) async throws {
        let task = lock.withLock { () -> Task<Void, Error> in
            let previous = tail
            let task = Task {
                _ = await previous?.result
                try await operation()
            }
            tail = task
            return task
        }
        try await task.value
    }
}

/// HEVC .mov writer. State is confined to `queue`: every method except close() runs on it.
private final class VideoFileWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "minutes.screen-writer", qos: .userInitiated)
    private(set) var firstFrameAt: Date?

    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let done = DispatchGroup()
    private var lastPTS: CMTime?
    private var lastSample: CMSampleBuffer?
    private var closed = false

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        // Without fragments the movie header is written only at finishWriting; a crash would lose the whole video.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        guard writer.canAdd(input) else { throw ScreenRecorderError(message: "Cannot write HEVC video at \(width)x\(height)") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ScreenRecorderError(message: "Cannot start writing \(url.lastPathComponent)")
        }
    }

    func append(_ sample: CMSampleBuffer) {
        guard !closed, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if let lastPTS {
            guard pts > lastPTS else { return }
        } else {
            writer.startSession(atSourceTime: pts)
            let lag = CMClockGetTime(CMClockGetHostTimeClock()).seconds - pts.seconds
            firstFrameAt = Date(timeIntervalSinceNow: -lag)
        }
        // Set even when the append fails: the session has started and must not start again.
        lastPTS = pts
        if input.append(sample) { lastSample = sample }
    }

    func finish() {
        guard !closed else { return }
        closed = true
        guard let lastPTS, writer.status == .writing else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            firstFrameAt = nil
            return
        }
        // No frames arrive while the window is static, and endSession alone does not stretch the last frame
        // past its own duration, so repeat it at the stop time to make the file last until stop.
        var end = lastPTS
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if now > lastPTS, let lastSample, input.isReadyForMoreMediaData,
           let repeated = try? CMSampleBuffer(copying: lastSample, withNewTiming: [
               CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid),
           ]),
           input.append(repeated) {
            end = now
        }
        self.lastSample = nil
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        done.enter()
        writer.finishWriting { [done] in done.leave() }
    }

    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                finish()
                done.notify(queue: .global()) { continuation.resume() }
            }
        }
    }
}
