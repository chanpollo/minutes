import Foundation

struct TranscriptionError: LocalizedError {
    let message: String
    /// The speech model is not on disk yet; the meeting is transcribed again once it is.
    var needsModels = false
    var errorDescription: String? { message }
}

/// Runs whisper.cpp on each track and merges both into transcript.md ordered by time.
enum Transcriber {
    static let modelsDir = Tools.support.appendingPathComponent("models")
    static let model = modelsDir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
    static let vadModel = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin")
    /// whisper's language code from Settings: detection picks English on quiet Thai audio and then loops.
    static var language: String { Settings.speechLanguage.code }

    typealias Line = TranscriptCleaner.Line

    private struct Named {
        let start: TimeInterval
        let speaker: String
        let text: String
    }

    /// One WAV, the name its lines keep when it holds one voice or the voices were not told apart, and whether to
    /// tell them apart.
    private struct Track {
        var audio: URL
        let speaker: String
        let separate: Bool
    }

    /// The mic is told apart only in a Voice recording started by hand, where several people may share it. In a call
    /// the mic is the owner, and what leaks from the speaker would otherwise become new Speakers.
    static func separatesMic(mode: RecordMode?, app: String?, bundleID: String?) -> Bool {
        mode == .voice && app == nil && bundleID == nil
    }

    /// whisper-cli's arguments for one track: a segment per token (`-ml 1 -ojf`) so each gets its own time, VAD so
    /// nothing is invented over silence, `--suppress-nst` against non-speech tokens. `maxContext` 0 is the second pass
    /// over a looping stretch, where the context carried between windows is what keeps the loop going.
    static func whisperArgs(audio: URL, output: URL, language: String, maxContext: Int = -1, vad: Bool) -> [String] {
        var args = ["-m", model.path, "-f", audio.path, "-l", language, "-ml", "1", "-mc", String(maxContext), "-ojf",
                    "-of", output.path, "-np", "-pp", "--suppress-nst"]
        if vad { args += ["--vad", "-vm", vadModel.path] }
        return args
    }

    /// What a run found on its way to transcript.md, for the evaluation harness (Tools/transcript-eval); the app leaves
    /// `observe` nil.
    enum Event {
        case track(speaker: String, voices: (raw: Int, absorbed: Int)?, parsed: [Line], cleaned: TranscriptCleaner.Result)
        case deduped(me: [Line], dropped: Int, leak: Int)
        case named([(start: TimeInterval, speaker: String, text: String)])
    }
    nonisolated(unsafe) static var observe: ((Event) -> Void)?

    /// With `id`, the folder is looked up again before each step: the user can rename the meeting while this runs.
    /// `progress` gets 0…1 over both tracks and the speaker separation, from whichever thread is working.
    static func transcribe(
        folder: URL, title: String, startedAt: Date, id: String? = nil, progress: ((Double) -> Void)? = nil
    ) throws -> URL {
        guard let whisper = Tools.whisper() else { throw TranscriptionError(message: "whisper-cli not found; run setup.sh") }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscriptionError(
                message: "Speech model missing; choose Download Speech Models… in the Minutes menu", needsModels: true)
        }
        if let id { Housekeeping.hold(id) }
        defer { if let id { Housekeeping.release(id) } }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Minutes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        func current() -> URL { id.flatMap(Workspace.folder(id:)) ?? folder }

        let meta = Workspace.readMeta(current())
        let mic = separatesMic(mode: meta?.recordMode, app: meta?.app, bundleID: meta?.bundleID)
        // whisper loads the model before opening the audio, so it reads a copy (a clone on APFS) that cannot move.
        var tracks: [Track] = []
        for (name, speaker) in [("me", "Me"), ("others", "Others")] {
            guard let source = AudioTracks.url(name, in: current()) else { continue }
            let copy = work.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: copy)
            tracks.append(Track(audio: copy, speaker: speaker, separate: name == "others" || mic))
        }
        let seconds = tracks.map { AudioTracks.seconds($0.audio) }
        let meter = ProgressMeter(steps: zip(tracks, seconds).flatMap { track, length in
            [length] + (track.separate && Diarizer.isEnabled && Diarizer.isAvailable ? [length * Diarizer.relativeCost] : [])
        }, report: progress)

        var perTrack: [[Line]] = []
        var retried: [[(from: TimeInterval, to: TimeInterval)]] = []
        for (track, length) in zip(tracks, seconds) {
            let done = try transcribe(track.audio, seconds: length, whisper: whisper, separate: track.separate, meter: meter,
                                      speaker: track.speaker)
            perTrack.append(done.lines)
            retried.append(done.retried)
        }
        if let me = tracks.firstIndex(where: { $0.speaker == "Me" }), let others = tracks.firstIndex(where: { $0.speaker == "Others" }) {
            // Only a mic that measurably carries the call loses its second-pass lines under far-end speech: without the
            // leak, that rule dropped most of the owner's lines in a lively call (11-13: 4 Me lines in 41 minutes).
            let leaks = AudioTracks.leak(me: tracks[me].audio, others: tracks[others].audio) >= AudioTracks.leakThreshold
            let leak = leaks ? TranscriptCleaner.dropLeak(me: perTrack[me], others: perTrack[others], retried: retried[me])
                             : (kept: perTrack[me], dropped: 0)
            let deduped = TranscriptCleaner.dedupe(me: leak.kept, others: perTrack[others])
            perTrack[me] = deduped.kept
            observe?(.deduped(me: deduped.kept, dropped: deduped.dropped, leak: leak.dropped))
        }
        let heard = perTrack.enumerated().flatMap { index, lines in lines.map { (line: $0, track: index) } }
            .sorted { $0.line.start < $1.line.start }
        let named = labels(heard.map { ($0.track, $0.line.voice) }, names: tracks.map(\.speaker))
        let lines = zip(heard, named).map { Named(start: $0.line.start, speaker: $1, text: $0.line.text) }
        observe?(.named(lines.map { ($0.start, $0.speaker, $0.text) }))

        let target = current()
        let title = id.flatMap { _ in Workspace.readMeta(target)?.title } ?? title
        let output = target.appendingPathComponent("transcript.md")
        try render(lines, title: title, startedAt: startedAt, seconds: seconds.max() ?? 0)
            .write(to: output, atomically: true, encoding: .utf8)
        CommentFile.refreshMarkdown(target)
        meter.finish()
        if Settings.compressAudio { AudioTracks.compress(in: current()) }
        return output
    }

    /// Splits 0…1 over steps weighted by their expected run time and reports it rising only.
    final class ProgressMeter: @unchecked Sendable {
        private let weights: [Double]
        private let report: ((Double) -> Void)?
        private let lock = NSLock()
        private var step = 0
        private var shown = -1.0

        init(steps: [Double], report: ((Double) -> Void)?) {
            let total = steps.reduce(0, +)
            weights = total > 0 ? steps.map { $0 / total } : steps.map { _ in 1 / Double(max(steps.count, 1)) }
            self.report = report
            send(0)
        }

        /// `fraction` of the current step is done.
        func update(_ fraction: Double) {
            let value = lock.withLock { () -> Double in
                let done = weights.prefix(step).reduce(0, +)
                return weights.indices.contains(step) ? done + weights[step] * min(max(fraction, 0), 1) : done
            }
            send(value)
        }

        func next() {
            lock.withLock { step += 1 }
            update(0)
        }

        func finish() { send(1) }

        // Whole percents only, so a caller on the main thread is not flooded.
        private func send(_ value: Double) {
            let rounded = (min(value, 1) * 100).rounded(.down) / 100
            let changed = lock.withLock { () -> Bool in
                guard rounded > shown else { return false }
                shown = rounded
                return true
            }
            if changed { report?(rounded) }
        }
    }

    /// A Thai word goes on from `before` into `next`: a vowel or tone mark that cannot start a syllable (ะ า ำ ๅ, the
    /// marks above and below), or `before` ending in a leading vowel, ั or ็. Breaking there split 75 words between
    /// lines ("ครั|บ", "ระหว่|าง").
    static func thaiJoins(_ before: [UInt8], _ next: String) -> Bool {
        if let first = next.unicodeScalars.first?.value,
           [0x0E30, 0x0E31, 0x0E32, 0x0E33, 0x0E45].contains(first) || (0x0E34...0x0E3A).contains(first)
            || (0x0E47...0x0E4E).contains(first) {
            return true
        }
        guard let last = String(bytes: before, encoding: .utf8)?.trimmingCharacters(in: .whitespaces).unicodeScalars.last?.value
        else { return false }
        return (0x0E40...0x0E44).contains(last) || last == 0x0E31 || last == 0x0E47
    }

    /// `whisper_print_progress_callback: progress =  27%` (it can pass 100% with VAD).
    static func whisperProgress(_ line: Substring) -> Double? {
        guard line.contains("progress ="), let percent = line.split(separator: "=").last?
            .trimmingCharacters(in: .whitespaces).dropLast(), let value = Double(percent) else { return nil }
        return min(value / 100, 1)
    }

    /// The track's lines, cleaned, with the voice heard in each when it holds more than one, and the stretches
    /// decoded a second time.
    private static func transcribe(
        _ audio: URL, seconds: TimeInterval, whisper: String, separate: Bool, meter: ProgressMeter, speaker: String
    ) throws -> (lines: [Line], retried: [(from: TimeInterval, to: TimeInterval)]) {
        guard seconds >= 1 else {
            meter.next()
            if separate && Diarizer.isEnabled && Diarizer.isAvailable { meter.next() }
            return ([], [])
        }

        let base = audio.deletingPathExtension()
        let json = try runWhisper(whisper, audio: audio, output: base, maxContext: -1, progress: meter.update)
        meter.next()

        let raw = separate ? voices(audio, meter: meter) : nil
        let found = raw.map {
            speaker == "Me" ? Diarizer.absorb($0, maxSeconds: Diarizer.roomAbsorbSeconds, share: Diarizer.roomAbsorbShare)
                            : Diarizer.absorb($0)
        }
        let segments = found.flatMap { Set($0.map(\.speaker)).count > 1 ? $0 : nil } ?? []
        let speakerAt = segments.isEmpty ? nil : { (time: TimeInterval) in Diarizer.speaker(at: time, in: segments) }
        let lines = voiced(try parseJSON(json, speakerAt: speakerAt), segments: segments)

        // A looping stretch is decoded once more on its own, without the context that kept the loop going.
        let cleaned = TranscriptCleaner.clean(lines) { from, to in
            let slice = base.appendingPathExtension("\(Int(from))-\(Int(to)).wav")
            try AudioTracks.slice(audio, from: from, to: to, into: slice)
            defer { try? FileManager.default.removeItem(at: slice) }
            let json = try runWhisper(whisper, audio: slice, output: slice.deletingPathExtension(), maxContext: 0, progress: nil)
            let shifted = try parseJSON(json, speakerAt: speakerAt.map { at in { at($0 + from) } }).map { line in
                var line = line
                line.start += from
                line.end += from
                return line
            }
            return voiced(shifted, segments: segments)
        }
        let voices = raw.flatMap { r in found.map { f in (raw: Set(r.map(\.speaker)).count, absorbed: Set(f.map(\.speaker)).count) } }
        observe?(.track(speaker: speaker, voices: voices, parsed: lines, cleaned: cleaned))
        return (cleaned.lines, cleaned.retried)
    }

    /// Lines between voices take the nearest one, however far.
    private static func voiced(_ lines: [Line], segments: [Diarizer.Segment]) -> [Line] {
        guard !segments.isEmpty else { return lines }
        return lines.map { line in
            var line = line
            line.voice = line.voice ?? Diarizer.speaker(at: line.start, in: segments, reach: .infinity)
            return line
        }
    }

    /// whisper over `audio`, the JSON it writes next to `output`.
    private static func runWhisper(
        _ whisper: String, audio: URL, output: URL, maxContext: Int, progress: ((Double) -> Void)?
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisper)
        process.arguments = whisperArgs(audio: audio, output: output, language: language, maxContext: maxContext,
                                        vad: FileManager.default.fileExists(atPath: vadModel.path))
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errorOutput = readLines(stderr) { line in
            if let value = whisperProgress(line) { progress?(value) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = String(decoding: errorOutput.suffix(500), as: UTF8.self)
            throw TranscriptionError(message: "whisper-cli failed on \(audio.lastPathComponent): \(tail)")
        }
        return try Data(contentsOf: output.appendingPathExtension("json"))
    }

    /// Reads a pipe to the end, calling `line` for each line as it arrives; returns the last 4 KB.
    static func readLines(_ pipe: Pipe, _ line: (Substring) -> Void) -> Data {
        let handle = pipe.fileHandleForReading
        var pending = Data()
        var tail = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            tail = (tail + chunk).suffix(4096)
            pending += chunk
            // whisper ends its progress lines with \n; the diarizer's with \r on some builds.
            while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                line(Substring(String(decoding: pending[pending.startIndex..<end], as: UTF8.self)))
                pending = Data(pending[(end + 1)...])
            }
        }
        if !pending.isEmpty { line(Substring(String(decoding: pending, as: UTF8.self))) }
        return tail
    }

    /// The diarizer's turns; nil when it is off, missing or fails.
    private static func voices(_ audio: URL, meter: ProgressMeter) -> [Diarizer.Segment]? {
        guard Diarizer.isEnabled, Diarizer.isAvailable else { return nil }
        defer { meter.next() }
        do {
            return try Diarizer.diarize(audio, progress: meter.update)
        } catch {
            NSLog("Minutes: speakers not separated in %@: %@", audio.lastPathComponent, error.localizedDescription)
            return nil
        }
    }

    /// "Speaker 1", "Speaker 2"… in order of first appearance; a single voice keeps `fallback`.
    static func label(_ speakers: [Int?], fallback: String) -> [String] {
        labels(speakers.map { (0, $0) }, names: [fallback])
    }

    /// Lines in time order, each with its track and voice: voices on tracks that hold more than one are numbered
    /// "Speaker 1", "Speaker 2"… across all tracks by when they are first heard; the rest keep their track's name.
    static func labels(_ heard: [(track: Int, voice: Int?)], names: [String]) -> [String] {
        var voices: [Int: Set<Int>] = [:]
        for case let (track, voice?) in heard { voices[track, default: []].insert(voice) }
        var numbers: [[Int]: Int] = [:]
        return heard.map { track, voice in
            guard let voice, voices[track, default: []].count > 1 else { return names[track] }
            let key = [track, voice]
            if numbers[key] == nil { numbers[key] = numbers.count + 1 }
            return "Speaker \(numbers[key]!)"
        }
    }

    private struct Output: Decodable {
        struct Piece: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            struct Token: Decodable { let text: String; let p: Double? }
            let offsets: Offsets
            let tokens: [Token]
        }
        let transcription: [Piece]
    }

    /// Rebuilds lines from whisper's `-ml 1 -ojf` output. With VAD, whisper's own segments run across silences and take
    /// the previous speech's end as their start; the token that spans a silence is stretched over it instead.
    /// With `speakerAt`, each token is given the voice heard at its time and a line breaks where the voice changes.
    /// Each line carries the mean of its tokens' `p`.
    static func parseJSON(_ json: Data, speakerAt: ((TimeInterval) -> Int?)? = nil) throws -> [Line] {
        // Tokens can end mid UTF-8 character (Thai), which makes the file invalid UTF-8: read it byte for byte as Latin-1.
        let latin1 = String(data: json, encoding: .isoLatin1) ?? ""
        let pieces = try JSONDecoder().decode(Output.self, from: Data(latin1.utf8)).transcription

        var lines: [Line] = []
        var bytes: [UInt8] = []
        var probabilities: [Double] = []
        var start: TimeInterval = 0, end: TimeInterval = 0
        var speaker: Int?
        // A voice change inside a sentence: where it would split the line, and to whom.
        var pending: (index: Int, token: Int, start: TimeInterval, speaker: Int)?
        var breakNext = false, afterSegment = false, afterSilence = false, movable = false

        func flush(_ text: [UInt8], _ ps: [Double], start: TimeInterval, end: TimeInterval, voice: Int?) {
            let mean = ps.isEmpty ? nil : ps.reduce(0, +) / Double(ps.count)
            lines.append(Line(start: start, end: end, text: String(decoding: text, as: UTF8.self), voice: voice, p: mean))
        }

        for piece in pieces {
            let from = TimeInterval(piece.offsets.from) / 1000, to = TimeInterval(piece.offsets.to) / 1000
            let spoken = piece.tokens.filter { !($0.text.hasPrefix("[_") && $0.text.hasSuffix("]")) }
            let text = spoken.flatMap { $0.text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }
            let endsSegment = piece.tokens.contains { $0.text.hasPrefix("[_TT_") }
            defer {
                if endsSegment { breakNext = true; afterSegment = true }
            }
            guard !text.isEmpty else { continue }

            let visible = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let punctuation = visible.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            let mark = visible.unicodeScalars.first.map { [.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory) } ?? false
            let silence = from - end > 1.0
            // A token stretched over a silence is spoken at its end when it opens a whisper segment, else at its start.
            let voice = speakerAt?(to - from > 1.5 ? (afterSegment ? to : from) : (from + to) / 2)
            let breakable = !punctuation && !mark && String(bytes: bytes, encoding: .utf8) != nil
                && !(text.first != UInt8(ascii: " ") && thaiJoins(bytes, visible))
            if bytes.isEmpty {
                start = from
                speaker = voice
            } else if voice != nil && speaker != nil && voice != speaker && !breakNext && !silence && from - start < 1 {
                // Whisper times the first words after a pause early, into the previous voice: the line takes the new one.
                speaker = voice
            } else if (breakNext || silence) && breakable {
                flush(bytes, probabilities, start: start, end: end, voice: speaker)
                bytes = []
                probabilities = []
                start = from
                speaker = voice ?? pending?.speaker ?? speaker
                pending = nil
                // A new whisper segment right at the edge of a silence is usually the next speech, timed early.
                movable = afterSegment && !afterSilence && !silence
                breakNext = false; afterSegment = false; afterSilence = false
            } else if silence {
                breakNext = true; afterSilence = true
            }

            // The diarizer's turn edges can be seconds off, so a change inside a sentence waits for the sentence to end;
            // only a change that lasts splits the line, at the first word it was heard on.
            if let voice, let current = speaker, voice != current, !bytes.isEmpty {
                if pending == nil && breakable && text.first == UInt8(ascii: " ") {
                    pending = (bytes.count, probabilities.count, from, voice)
                }
                if let split = pending, from - split.start >= 3 {
                    flush(Array(bytes[..<split.index]), Array(probabilities[..<split.token]), start: start, end: split.start, voice: current)
                    bytes.removeFirst(split.index)
                    probabilities.removeFirst(split.token)
                    start = split.start
                    speaker = split.speaker
                    pending = nil
                }
            } else if voice != nil && voice == speaker {
                pending = nil
            }
            if speaker == nil { speaker = voice }
            bytes += text
            probabilities += spoken.compactMap(\.p)

            if to - from > 1.5 {
                if movable && from - start <= 0.5 {
                    start = to
                } else {
                    breakNext = true; afterSilence = true
                }
                movable = false
            }
            if let last = visible.last, ".?!".contains(last) { breakNext = true }
            end = to
        }
        if !bytes.isEmpty { flush(bytes, probabilities, start: start, end: end, voice: speaker) }
        return lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var line = line
            line.text = text
            return line
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static func render(_ lines: [Named], title: String, startedAt: Date, seconds: TimeInterval) -> String {
        let date = DateFormatter()
        // A Thai system calendar would otherwise print Buddhist-era years.
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(title)\n\n\(date.string(from: startedAt)) · \(Int((seconds / 60).rounded())) min\n"

        // Consecutive lines from the same speaker read as one paragraph.
        var speaker: String?
        for line in lines {
            if line.speaker != speaker {
                out += "\n**[\(clock(line.start))] \(line.speaker):** "
                speaker = line.speaker
            } else {
                out += " "
            }
            out += line.text
        }
        if lines.isEmpty { out += "\nNo speech detected.\n" }
        return out + "\n"
    }
}
