import Foundation

struct DiarizationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Tells the voices in a track apart with sherpa-onnx: pyannote segmentation, then clustered speaker embeddings.
enum Diarizer {
    typealias Segment = (start: TimeInterval, end: TimeInterval, speaker: Int)

    static let segmentationModel = Transcriber.modelsDir
        .appendingPathComponent("sherpa-onnx-pyannote-segmentation-3-0/model.onnx")
    static let embeddingModel = Transcriber.modelsDir
        .appendingPathComponent("3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")

    // Measured on four recordings (30 Oct 2026): at 0.65 the extra voices are phantoms under 20 s, which `absorb`
    // removes (line1003 48 → 7); 0.70 and up already merge two people who alternate every 5 s (teams1038), and 0.80
    // leaves line1030 one voice. A split can be undone by renaming both labels to one name; a merge cannot.
    static let threshold = 0.65

    /// A voice with less speech than this, or than `absorbShare` of the track's, is a phantom of the clustering.
    static let absorbSeconds: TimeInterval = 20
    static let absorbShare = 0.05
    /// A room on the mic (Voice mode) splits each person into many voices: 20 s left 14–57 labels in meetings of
    /// 6–12 invitees, and in one 37 of 50 labels held under 2 % of the text.
    static let roomAbsorbSeconds: TimeInterval = 60
    static let roomAbsorbShare = 0.03

    /// Its run time against whisper's on the same audio, for one progress bar over both (measured on an M4).
    static let relativeCost = 0.3

    static var isEnabled: Bool {
        get { Settings.separateSpeakers }
        set { Settings.separateSpeakers = newValue }
    }

    static var isAvailable: Bool {
        Tools.diarizer() != nil
            && FileManager.default.fileExists(atPath: segmentationModel.path)
            && FileManager.default.fileExists(atPath: embeddingModel.path)
    }

    /// Speaker turns of a 16 kHz mono track, in the order the tool prints them. Blocking.
    static func diarize(_ audio: URL, progress: ((Double) -> Void)? = nil) throws -> [Segment] {
        guard let tool = Tools.diarizer() else { throw DiarizationError(message: "speaker diarizer not found; run setup.sh") }
        // The tool reads WAV only.
        var wav = audio
        if audio.pathExtension.lowercased() != "wav" {
            wav = FileManager.default.temporaryDirectory.appendingPathComponent("Minutes-\(UUID().uuidString).wav")
            try AudioTracks.decodeToWAV(audio, to: wav)
        }
        defer { if wav != audio { try? FileManager.default.removeItem(at: wav) } }
        let threads = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [
            "--clustering.cluster-threshold=\(threshold)",
            "--segmentation.num-threads=\(threads)",
            "--embedding.num-threads=\(threads)",
            "--segmentation.pyannote-model=\(segmentationModel.path)",
            "--embedding.model=\(embeddingModel.path)",
            wav.path,
        ]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Progress goes to stderr, a line per window: drain it alongside stdout so neither pipe fills up.
        let errors = Tail()
        let reader = DispatchGroup()
        DispatchQueue.global().async(group: reader) {
            errors.data = Transcriber.readLines(stderr) { line in
                if let value = percent(line) { progress?(value) }
            }.suffix(500)
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        reader.wait()

        guard process.terminationStatus == 0 else {
            let tail = String(decoding: errors.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiarizationError(message: "diarizer exited with \(process.terminationStatus): \(tail)")
        }
        return parse(String(decoding: output, as: UTF8.self))
    }

    /// `progress 12.17%`
    static func percent(_ line: Substring) -> Double? {
        guard line.hasPrefix("progress "), line.hasSuffix("%"), let value = Double(line.dropFirst(9).dropLast()) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    /// Reads `0.470 -- 8.384 speaker_00` lines; the configuration and progress lines around them are skipped.
    static func parse(_ output: String) -> [Segment] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 4, parts[1] == "--", parts[3].hasPrefix("speaker_"),
                  let start = TimeInterval(parts[0]), let end = TimeInterval(parts[2]), end > start,
                  let speaker = Int(parts[3].dropFirst("speaker_".count))
            else { return nil }
            return (start, end, speaker)
        }
    }

    /// Folds the voices with little speech into the others, smallest first: each segment goes to the voice whose
    /// segment lies nearest in time (an overlap counts as touching; the longer segment wins a tie). The cutoff is the
    /// smaller of `maxSeconds` and `share` of the track's speech, and at least `minVoices` voices are left.
    static func absorb(
        _ segments: [Segment], maxSeconds: TimeInterval = absorbSeconds, share: Double = absorbShare, minVoices: Int = 2
    ) -> [Segment] {
        var segments = segments
        while true {
            var totals: [Int: TimeInterval] = [:]
            for segment in segments { totals[segment.speaker, default: 0] += segment.end - segment.start }
            guard totals.count > minVoices else { break }
            let cutoff = min(maxSeconds, share * totals.values.reduce(0, +))
            guard let small = totals.filter({ $0.value < cutoff }).min(by: { $0.value < $1.value })?.key else { break }
            let hosts = segments.filter { $0.speaker != small }
            segments = segments.map { segment in
                guard segment.speaker == small else { return segment }
                let gap = { (host: Segment) in max(0, max(segment.start, host.start) - min(segment.end, host.end)) }
                let nearest = hosts.min { a, b in
                    let ga = gap(a), gb = gap(b)
                    return ga != gb ? ga < gb : a.end - a.start > b.end - b.start
                }!
                return (segment.start, segment.end, nearest.speaker)
            }
        }
        return segments
    }

    /// The speaker talking at `time`: the longest segment that covers it, else the nearest one within `reach` seconds.
    static func speaker(at time: TimeInterval, in segments: [Segment], reach: TimeInterval = 1) -> Int? {
        if let covering = segments.filter({ $0.start <= time && time <= $0.end }).max(by: { $0.end - $0.start < $1.end - $1.start }) {
            return covering.speaker
        }
        let distance = { (segment: Segment) in time < segment.start ? segment.start - time : time - segment.end }
        guard let nearest = segments.min(by: { distance($0) < distance($1) }), distance(nearest) <= reach else { return nil }
        return nearest.speaker
    }

    private final class Tail: @unchecked Sendable {
        var data = Data()
    }
}
