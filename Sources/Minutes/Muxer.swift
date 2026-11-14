import AVFoundation
import Foundation

struct MuxError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Builds meeting.mp4: the screen video passed through as it is, plus every audio track mixed into one AAC track.
enum Muxer {
    private static let sampleRate = 44_100

    private struct Source {
        // A track holds its asset weakly; once the asset is gone its loads fail with -12780.
        let assets: [AVAsset]
        let composition: AVMutableComposition
        let video: AVMutableCompositionTrack
        let videoFormat: CMFormatDescription?
        let transform: CGAffineTransform
        /// The video starts after the audio.
        let startsLate: Bool
        let audio: [AVMutableCompositionTrack]
    }

    /// Blocking; call off the main thread. videoOffset is the time from the start of the WAVs to the first video frame.
    static func mux(video: URL, audio: [URL], videoOffset: TimeInterval, to output: URL) throws {
        let source = try wait { try await compose(video: video, audio: audio, videoOffset: videoOffset) }
        // Written under a hidden name and moved into place when complete: a killed mux never leaves
        // a broken output, and a failed re-mux keeps the previous one.
        let fm = FileManager.default
        let partial = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).partial.\(output.pathExtension)")
        try? fm.removeItem(at: partial)
        do {
            try write(source, to: partial, name: output.lastPathComponent)
            if fm.fileExists(atPath: output.path) {
                _ = try fm.replaceItemAt(output, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: output)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// Where the picture starts. Files muxed before the head was filled keep an empty edit up to their first frame.
    static func firstFrame(in asset: AVAsset) async -> TimeInterval {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let segments = try? await track.load(.segments),
              segments.first?.isEmpty == true,
              let start = segments.first(where: { !$0.isEmpty })?.timeMapping.target.start,
              start.seconds.isFinite
        else { return 0 }
        return start.seconds
    }

    private static func compose(video: URL, audio: [URL], videoOffset: TimeInterval) async throws -> Source {
        guard FileManager.default.fileExists(atPath: video.path) else {
            throw MuxError(message: "\(video.lastPathComponent) not found")
        }
        let composition = AVMutableComposition()
        var assets: [AVAsset] = [AVURLAsset(url: video)]
        guard let videoTrack = try await assets[0].loadTracks(withMediaType: .video).first,
              let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MuxError(message: "No video track in \(video.lastPathComponent)") }
        let (range, formats, transform) = try await videoTrack.load(.timeRange, .formatDescriptions, .preferredTransform)

        // A video that started before the audio loses its head, so both begin at zero.
        let offset = CMTime(seconds: videoOffset, preferredTimescale: 600)
        let head = offset < .zero ? .zero - offset : .zero
        guard range.duration > head else { throw MuxError(message: "The video ends before the audio starts") }
        try videoOut.insertTimeRange(CMTimeRange(start: range.start + head, end: range.end), of: videoTrack,
                                     at: offset < .zero ? .zero : offset)

        var audioOut: [AVMutableCompositionTrack] = []
        for url in audio where FileManager.default.fileExists(atPath: url.path) {
            // Empty or unreadable tracks are left out; the video is still worth keeping.
            let asset = AVURLAsset(url: url)
            assets.append(asset)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let span = try? await track.load(.timeRange), span.duration > .zero,
                  let out = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try out.insertTimeRange(span, of: track, at: .zero)
            audioOut.append(out)
        }
        return Source(assets: assets, composition: composition, video: videoOut, videoFormat: formats.first,
                      transform: transform, startsLate: offset > .zero, audio: audioOut)
    }

    private static func write(_ source: Source, to url: URL, name: String) throws {
        let reader = try AVAssetReader(asset: source.composition)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // No output settings: samples are copied, so the hvc1 stream is never re-encoded.
        let videoOutput = AVAssetReaderTrackOutput(track: source.video, outputSettings: nil)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: source.videoFormat)
        videoInput.transform = source.transform
        var pumps = [Pump(output: videoOutput, input: videoInput, fillsHead: source.startsLate)]

        if !source.audio.isEmpty {
            let mix = AVAssetReaderAudioMixOutput(audioTracks: source.audio, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let aac = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            pumps.append(Pump(output: mix, input: aac))
        }

        for pump in pumps {
            pump.output.alwaysCopiesSampleData = false
            pump.input.expectsMediaDataInRealTime = false
            guard reader.canAdd(pump.output), writer.canAdd(pump.input) else {
                throw MuxError(message: "Cannot copy the \(pump.input.mediaType.rawValue) track into \(name)")
            }
            reader.add(pump.output)
            writer.add(pump.input)
        }

        guard reader.startReading() else { throw reader.error ?? MuxError(message: "Cannot read the recording") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? MuxError(message: "Cannot write \(name)")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        for (i, pump) in pumps.enumerated() {
            group.enter()
            pump.run(on: DispatchQueue(label: "minutes.mux.\(i)"), group: group)
        }
        // A failed writer stops asking the other input for data, so its pump would never leave the group.
        while group.wait(timeout: .now() + 0.5) == .timedOut {
            if writer.status == .failed || reader.status == .failed { break }
        }

        guard writer.status != .failed, reader.status != .failed else {
            let error = writer.error ?? reader.error
            reader.cancelReading()
            writer.cancelWriting()
            throw error ?? MuxError(message: "Writing \(name) failed")
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw writer.error ?? MuxError(message: "Writing \(name) failed")
        }
    }

    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        /// Before its first frame a late video has only the composition's empty edit, which the player shows as black.
        /// The first frame is written a second time from zero instead, so every frame keeps its time.
        private var fillsHead: Bool
        /// The first frame, waiting while its copy from zero goes in.
        private var pending: CMSampleBuffer?
        private var done = false

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, fillsHead: Bool = false) {
            self.output = output
            self.input = input
            self.fillsHead = fillsHead
        }

        func run(on queue: DispatchQueue, group: DispatchGroup) {
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !done else { return }
                while input.isReadyForMoreMediaData {
                    let sample: CMSampleBuffer?
                    if let held = pending {
                        pending = nil
                        sample = held
                    } else {
                        sample = next()
                    }
                    if let sample, input.append(sample) { continue }
                    done = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        private func next() -> CMSampleBuffer? {
            guard let sample = output.copyNextSampleBuffer() else { return nil }
            guard fillsHead else { return sample }
            // The empty edit arrives as a buffer with no samples.
            if sample.numSamples == 0 { return next() }
            fillsHead = false
            let start = sample.presentationTimeStamp
            guard start > .zero, let head = try? CMSampleBuffer(copying: sample, withNewTiming: [
                CMSampleTimingInfo(duration: start, presentationTimeStamp: .zero, decodeTimeStamp: .zero),
            ]) else { return sample }
            pending = sample
            return head
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    // The AVAsset load APIs are async only; this bridges them for a caller already off the main thread.
    private static func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}
