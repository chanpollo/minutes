import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A still moment of the meeting video, saved as frames/hh-mm-ss.jpg with the text read from it.
struct VideoFrame: Codable, Equatable {
    var time: TimeInterval
    /// Relative to the meeting folder, e.g. `frames/00-12-34.jpg`.
    var file: String
    var text: String
}

struct FrameError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// frames/ in a meeting folder: the pictures the summary may show and the ones captured from the player.
enum Frames {
    static let folderName = "frames"
    static let listName = "frames/frames.json"

    /// `frames/00-12-34.jpg`
    static func file(at seconds: TimeInterval) -> String {
        "\(folderName)/" + MeetingFormat.longClock(seconds).replacingOccurrences(of: ":", with: "-") + ".jpg"
    }

    /// The video time a frame file was taken at, from its name.
    static func time(of file: String) -> TimeInterval? {
        let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        return MeetingFormat.seconds(fromStamp: name.replacingOccurrences(of: "-", with: ":"))
    }

    static func read(_ folder: URL) -> [VideoFrame]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(listName)) else { return nil }
        return try? JSONDecoder().decode([VideoFrame].self, from: data)
    }

    static func write(_ frames: [VideoFrame], to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(frames).write(to: folder.appendingPathComponent(listName), options: .atomic)
    }

    // `![alt](frames/…)`; anything else in the Markdown is left alone.
    private static let linkPattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\((frames/[^)\s]+)\)"#)

    /// Every picture link into frames/ in `markdown`, in order: (alt text, path, range of the whole link).
    static func links(in markdown: String) -> [(alt: String, path: String, range: Range<String.Index>)] {
        linkPattern.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).compactMap { match in
            guard let whole = Range(match.range, in: markdown), let alt = Range(match.range(at: 1), in: markdown),
                  let path = Range(match.range(at: 2), in: markdown)
            else { return nil }
            return (String(markdown[alt]), String(markdown[path]), whole)
        }
    }

    /// A line that is only one picture link, as the summary and Capture write them.
    static func pictureLine(_ line: String) -> (alt: String, path: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let link = links(in: trimmed).first, link.range == trimmed.startIndex..<trimmed.endIndex else { return nil }
        return (link.alt, link.path)
    }

    /// Frames the summary or notes show that exist on disk; these go to Drive with the text files.
    static func referenced(in folder: URL) -> [String] {
        var seen = Set<String>()
        return ["summary.md", "notes.md"].flatMap { name -> [String] in
            let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return links(in: text).map(\.path)
        }.filter { path in
            !path.contains("..") && seen.insert(path).inserted
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
        }
    }

    /// Drops picture links whose file is not one of `known`, repeats of a picture and any past the first `limit`;
    /// a line left empty by that goes too.
    static func keepKnown(_ markdown: String, known: Set<String>, limit: Int = .max) -> String {
        var lines: [String] = []
        var used = Set<String>()
        for line in markdown.components(separatedBy: "\n") {
            let found = links(in: line)
            let dropped = found.filter { link in
                guard known.contains(link.path), used.count < limit, !used.contains(link.path) else { return true }
                used.insert(link.path)
                return false
            }
            guard !dropped.isEmpty else {
                lines.append(line)
                continue
            }
            var kept = line
            for link in dropped.reversed() { kept.removeSubrange(link.range) }
            if kept.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            lines.append(kept.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression))
        }
        return lines.joined(separator: "\n")
    }

    /// The candidate list given to the summary: time, file and the text read from each picture, trimmed.
    static func promptList(_ frames: [VideoFrame], perFrame: Int = 400, total: Int = 8000) -> String {
        guard !frames.isEmpty else { return "" }
        var out = "Pictures from the meeting's screen video:\n"
        for frame in frames {
            var text = frame.text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")
            if text.count > perFrame { text = String(text.prefix(perFrame)) + "…" }
            let entry = "[\(MeetingFormat.longClock(frame.time))] \(frame.file): \(text.isEmpty ? "(no text)" : text)\n"
            if out.count + entry.count > total { break }
            out += entry
        }
        return out
    }

    /// Saves the video's frame at `seconds` as frames/hh-mm-ss.jpg (kept if that second was saved before) and returns
    /// its relative path. Blocking; call off the main thread.
    static func capture(video: URL, at seconds: TimeInterval, into folder: URL) throws -> String {
        let path = file(at: seconds)
        let target = folder.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: target.path) { return path }
        // Before an older video's first frame there is no picture; that frame is what the page shows there.
        let image = try FrameExtractor.image(of: video, at: max(seconds, FrameExtractor.firstFrame(of: video)))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FrameExtractor.writeJPEG(image, to: target)
        return path
    }
}

/// Finds the moments of the meeting video where the screen changed and then stayed still (slides, shared documents),
/// saves them to frames/ and reads their text with Vision.
final class FrameExtractor: @unchecked Sendable {
    static let shared = FrameExtractor()

    static let step: TimeInterval = 1
    static let stillFor: TimeInterval = 3
    static let limit = 40
    static let columns = 64, rows = 36
    // A cell counts as changed when its mean brightness moves by more than this (0…255).
    static let cellChange = 12
    static let stillChanged = 0.01
    static let distinctChanged = 0.04
    // Cells changing in half the steps of this many are a live video tile or similar, and are ignored.
    static let busyWindow = 20
    static let busyShare = 0.3

    private final class Job {
        let done = DispatchGroup()
        var cancelled = false
    }

    private let queue = DispatchQueue(label: "Minutes.frames", qos: .utility)
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]

    /// True when Settings ask for pictures and the meeting has a video but no frames.json yet.
    static func wanted(in folder: URL) -> Bool {
        let fm = FileManager.default
        return Settings.summaryPictures && Settings.summaryProvider != .off
            && fm.fileExists(atPath: folder.appendingPathComponent("meeting.mp4").path)
            && !fm.fileExists(atPath: folder.appendingPathComponent(Frames.listName).path)
    }

    /// Extracts in the background; the folder is looked up by id when the job starts.
    func start(meetingID id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard jobs[id] == nil else { return }
        let job = Job()
        jobs[id] = job
        job.done.enter()
        Housekeeping.hold(id)
        queue.async { [self] in
            defer { finish(id, job) }
            guard !job.cancelled, let folder = Workspace.folder(id: id), Self.wanted(in: folder) else { return }
            _ = try? Self.extract(folder: folder, locate: Self.locator(folder, id)) { job.cancelled }
        }
    }

    /// The pictures the summary may use: waits for a running job, or extracts now when none ran. Blocking.
    func prepare(folder: URL, meetingID id: String?) -> [VideoFrame] {
        guard Settings.summaryPictures else { return [] }
        let running = id.flatMap { id in lock.withLock { jobs[id] } }
        if let running {
            running.done.wait()
        } else if Self.wanted(in: folder) {
            let job = Job()
            if let id {
                lock.withLock { jobs[id] = job }
                job.done.enter()
                Housekeeping.hold(id)
            }
            _ = try? Self.extract(folder: folder, locate: Self.locator(folder, id)) { job.cancelled }
            if let id { finish(id, job) }
        }
        // Renamed while extracting: frames/ moved with the folder.
        let current = id.flatMap(Workspace.folder(id:)) ?? folder
        // The job ended without a list (renamed or stopped mid-way): once more, on the folder as it is now.
        if running != nil, Self.wanted(in: current) {
            if let id { Housekeeping.hold(id) }
            _ = try? Self.extract(folder: current, locate: Self.locator(current, id))
            if let id { Housekeeping.release(id) }
        }
        return (Frames.read(current) ?? []).filter {
            FileManager.default.fileExists(atPath: current.appendingPathComponent($0.file).path)
        }
    }

    /// The meeting's folder now: found by id after a rename, nil once it is deleted.
    private static func locator(_ folder: URL, _ id: String?) -> () -> URL? {
        {
            if let id, let found = Workspace.folder(id: id) { return found }
            return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
        }
    }

    func cancel(meetingID id: String) {
        lock.withLock { jobs[id]?.cancelled = true }
    }

    func cancelAll() {
        lock.withLock { jobs.values.forEach { $0.cancelled = true } }
    }

    private func finish(_ id: String, _ job: Job) {
        lock.withLock { if jobs[id] === job { jobs[id] = nil } }
        Housekeeping.release(id)
        job.done.leave()
    }

    // MARK: Extraction

    struct Sample {
        let time: TimeInterval
        let cells: [UInt8]
    }

    struct Moment: Equatable {
        /// When the screen became still.
        var time: TimeInterval
        /// A time inside the still stretch to take the picture from; later than `time` when the slide grew in place.
        var shot: TimeInterval
        var shotRange: ClosedRange<TimeInterval>
        var length: TimeInterval
    }

    /// Writes frames/*.jpg and frames/frames.json for the folder's meeting.mp4. Blocking. `locate` finds the
    /// meeting's folder again before each write, since it may be renamed or deleted while the video decodes.
    @discardableResult
    static func extract(folder: URL, locate: (() -> URL?)? = nil, isCancelled: () -> Bool = { false }) throws -> [VideoFrame] {
        let locate = locate ?? { folder }
        let samples = try samples(of: folder.appendingPathComponent("meeting.mp4"), isCancelled: isCancelled)
        let moments = moments(samples)
        let fm = FileManager.default
        func current() throws -> URL {
            guard let folder = locate(), fm.fileExists(atPath: folder.path) else { throw CancellationError() }
            return folder
        }
        var frames: [VideoFrame] = []
        // Only files this run created are removed when it stops; a Capture of the same second stays.
        var written: [String] = []
        do {
            let directory = try current().appendingPathComponent(Frames.folderName)
            if !fm.fileExists(atPath: directory.path) { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
            for moment in moments {
                if isCancelled() { throw CancellationError() }
                let file = Frames.file(at: moment.time)
                let folder = try current()
                let url = folder.appendingPathComponent(file)
                let image: CGImage
                if fm.fileExists(atPath: url.path), let saved = loadImage(url) {
                    image = saved
                } else {
                    image = try self.image(of: folder.appendingPathComponent("meeting.mp4"), at: moment.shot, within: moment.shotRange)
                    try writeJPEG(image, to: url)
                    written.append(file)
                }
                frames.append(VideoFrame(time: moment.time.rounded(.down), file: file, text: recognizeText(image)))
            }
            try Frames.write(frames, to: try current())
        } catch {
            if let folder = locate() { written.forEach { try? fm.removeItem(at: folder.appendingPathComponent($0)) } }
            throw error
        }
        return frames
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The video's picture once a `step`, each as a grid of mean brightness. Decodes in order, which is far cheaper
    /// than seeking with 30 s between key frames.
    static func samples(of video: URL, isCancelled: () -> Bool = { false }) throws -> [Sample] {
        let asset = AVURLAsset(url: video)
        guard let track = try wait({ try await asset.loadTracks(withMediaType: .video).first }) else {
            throw FrameError(message: "No video track in \(video.lastPathComponent)")
        }
        let range = try wait { try await track.load(.timeRange) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FrameError(message: "Could not read \(video.lastPathComponent)") }

        var samples: [Sample] = []
        var shown: CMSampleBuffer?
        var next: TimeInterval = 0
        func record(until end: TimeInterval) {
            guard let shown else { return }
            var cells: [UInt8]?
            while next < end {
                cells = cells ?? signature(shown)
                guard let cells else { return }
                samples.append(Sample(time: next, cells: cells))
                next += step
            }
        }
        while let buffer = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            guard CMSampleBufferGetImageBuffer(buffer) != nil else { continue }
            let time = buffer.presentationTimeStamp.seconds
            if shown == nil {
                next = (time / step).rounded(.up) * step
            } else {
                record(until: time)
            }
            shown = buffer
        }
        if reader.status == .failed { throw reader.error ?? FrameError(message: "Could not read \(video.lastPathComponent)") }
        record(until: range.end.seconds + 0.001)
        return samples
    }

    /// Mean brightness of each cell of a columns × rows grid, from a few points per cell of the luma plane.
    private static func signature(_ buffer: CMSampleBuffer) -> [UInt8]? {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let points = 4
        var cells = [UInt8](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = 0
                for py in 0..<points {
                    let y = (row * points + py) * height / (rows * points) + height / (rows * points * 2)
                    for px in 0..<points {
                        let x = (column * points + px) * width / (columns * points) + width / (columns * points * 2)
                        sum += Int(luma[min(y, height - 1) * stride + min(x, width - 1)])
                    }
                }
                cells[row * columns + column] = UInt8(sum / (points * points))
            }
        }
        return cells
    }

    /// Still stretches of at least `stillFor` that differ from every earlier one, at most `limit` (the longest).
    static func moments(_ samples: [Sample]) -> [Moment] {
        let count = columns * rows
        guard samples.count > 1 else { return [] }
        // Cells that changed between each sample and the next.
        let steps: [[Int]] = zip(samples, samples.dropFirst()).map { a, b in
            (0..<count).filter { abs(Int(a.cells[$0]) - Int(b.cells[$0])) > cellChange }
        }
        // Cells that keep changing over the next stretch (a speaker's video tile beside a slide) are left out of every
        // comparison, or a slide would never look still.
        func busy(from start: Int) -> [Bool] {
            // Cuts and full-screen motion change most cells at once; only small, local changes count here.
            let span = (start..<min(steps.count, start + busyWindow)).filter { Double(steps[$0].count) < busyShare * Double(count) }
            var counts = [Int](repeating: 0, count: count)
            for step in span { for cell in steps[step] { counts[cell] += 1 } }
            let needed = max(2, (span.count + 1) / 2)
            return counts.map { $0 >= needed }
        }
        func changed(_ a: [UInt8], _ b: [UInt8], ignoring mask: [Bool]) -> Double {
            var watched = 0, moved = 0
            for cell in 0..<count where !mask[cell] {
                watched += 1
                if abs(Int(a[cell]) - Int(b[cell])) > cellChange { moved += 1 }
            }
            return watched == 0 ? 1 : Double(moved) / Double(watched)
        }
        func blank(_ cells: [UInt8], ignoring mask: [Bool]) -> Bool {
            let values = (0..<count).filter { !mask[$0] }.map { Double(cells[$0]) }
            guard !values.isEmpty else { return true }
            let mean = values.reduce(0, +) / Double(values.count)
            return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count) < 4
        }

        var kept: [(moment: Moment, cells: [UInt8], mask: [Bool])] = []
        var start = 0
        while start < samples.count {
            let mask = busy(from: start)
            var end = start
            // Mostly moving (scrolling, a full-screen video): nothing here is still.
            if Double(mask.filter { $0 }.count) <= busyShare * Double(count) {
                while end + 1 < samples.count,
                      changed(samples[end + 1].cells, samples[end].cells, ignoring: mask) <= stillChanged,
                      changed(samples[end + 1].cells, samples[start].cells, ignoring: mask) <= stillChanged {
                    end += 1
                }
            }
            defer { start = end + 1 }
            let first = samples[start], last = samples[end]
            let length = last.time - first.time + step
            guard length >= stillFor, !blank(first.cells, ignoring: mask) else { continue }
            let middle = first.time + min(1, (last.time - first.time) / 2)
            let moment = Moment(time: first.time, shot: middle, shotRange: first.time...last.time, length: length)
            let same = kept.lastIndex { earlier in
                let both = zip(earlier.mask, mask).map { $0 || $1 }
                return changed(earlier.cells, first.cells, ignoring: both) < distinctChanged
            }
            if let same {
                // The same slide again right after itself (a bullet appeared): its fuller state, from its first time.
                if same == kept.count - 1 {
                    kept[same].moment.shot = moment.shot
                    kept[same].moment.shotRange = moment.shotRange
                    kept[same].moment.length += length
                    kept[same].cells = first.cells
                }
                continue
            }
            kept.append((moment, first.cells, mask))
        }
        var moments = kept.map(\.moment)
        if moments.count > limit {
            moments = Array(moments.sorted { $0.length > $1.length }.prefix(limit)).sorted { $0.time < $1.time }
        }
        return moments
    }

    // MARK: Pictures

    /// The frame at `seconds` at the video's full size; any frame within `range` will do and is quicker to find.
    static func image(of video: URL, at seconds: TimeInterval, within range: ClosedRange<TimeInterval>? = nil) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        let range = range ?? seconds...seconds
        generator.requestedTimeToleranceBefore = CMTime(seconds: max(0, seconds - range.lowerBound), preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: max(0, range.upperBound - seconds), preferredTimescale: 600)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try wait { try await generator.image(at: time).image }
    }

    static func firstFrame(of video: URL) -> TimeInterval {
        (try? wait { await Muxer.firstFrame(in: AVURLAsset(url: video)) }) ?? 0
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FrameError(message: "Could not write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: partial)
            throw FrameError(message: "Could not write \(url.lastPathComponent)")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: url)
        }
    }

    /// Thai and English text in reading order, one line per line Vision found.
    static func recognizeText(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        request.recognitionLanguages = ["th-TH", "en-US"].filter(supported.contains)
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private final class Box<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    // AVFoundation's loads are async only; this bridges them for a caller already off the main thread.
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
