import Foundation

struct TranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs whisper.cpp on each track and merges both into transcript.md ordered by time.
enum Transcriber {
    static let modelsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Minutes/models")
    static let model = modelsDir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
    static let vadModel = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin")
    // Detected per track: a forced "th" turns English speakers into Thai nonsense.
    static let language = "auto"

    private struct Line {
        let start: TimeInterval
        let speaker: String
        let text: String
    }

    /// With `id`, the folder is looked up again before each step: the user can rename the meeting while this runs.
    static func transcribe(folder: URL, title: String, startedAt: Date, id: String? = nil) throws -> URL {
        guard let whisper = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { throw TranscriptionError(message: "whisper-cli not found; run setup.sh") }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscriptionError(message: "Speech model missing; run setup.sh")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Minutes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        func current() -> URL { id.flatMap(Workspace.folder(id:)) ?? folder }

        var lines: [Line] = []
        var seconds: TimeInterval = 0
        for (name, speaker) in [("me.wav", "Me"), ("others.wav", "Others")] {
            let source = current().appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            // whisper loads the model before opening the audio, so it reads a copy (a clone on APFS) that cannot move.
            let wav = work.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: wav)
            seconds = max(seconds, audioSeconds(wav))
            lines += try transcribe(wav, speaker: speaker, whisper: whisper)
        }
        lines.sort { $0.start < $1.start }

        let target = current()
        let title = id.flatMap { _ in Workspace.readMeta(target)?.title } ?? title
        let output = target.appendingPathComponent("transcript.md")
        try render(lines, title: title, startedAt: startedAt, seconds: seconds).write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    private static func transcribe(_ wav: URL, speaker: String, whisper: String) throws -> [Line] {
        guard audioSeconds(wav) >= 1 else { return [] }

        let base = wav.deletingPathExtension()
        // -ml 1 makes a segment per token, so each token gets its own time mapped back through VAD.
        var args = ["-m", model.path, "-f", wav.path, "-l", language, "-ml", "1", "-ojf", "-of", base.path, "-np"]
        // Without VAD, whisper invents phrases over silence.
        if FileManager.default.fileExists(atPath: vadModel.path) {
            args += ["--vad", "-vm", vadModel.path]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisper)
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = String(decoding: errorOutput.suffix(500), as: UTF8.self)
            throw TranscriptionError(message: "whisper-cli failed on \(wav.lastPathComponent): \(tail)")
        }

        let json = try Data(contentsOf: base.appendingPathExtension("json"))
        return try parseJSON(json).map { Line(start: $0.start, speaker: speaker, text: $0.text) }
    }

    // Tracks are 16 kHz mono 16-bit: 32,000 bytes a second.
    private static func audioSeconds(_ wav: URL) -> TimeInterval {
        TimeInterval((try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 32_000
    }

    private struct Output: Decodable {
        struct Piece: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            struct Token: Decodable { let text: String }
            let offsets: Offsets
            let tokens: [Token]
        }
        let transcription: [Piece]
    }

    /// Rebuilds lines from whisper's `-ml 1 -ojf` output. With VAD, whisper's own segments run across silences and take
    /// the previous speech's end as their start; the token that spans a silence is stretched over it instead.
    static func parseJSON(_ json: Data) throws -> [(start: TimeInterval, text: String)] {
        // Tokens can end mid UTF-8 character (Thai), which makes the file invalid UTF-8: read it byte for byte as Latin-1.
        let latin1 = String(data: json, encoding: .isoLatin1) ?? ""
        let pieces = try JSONDecoder().decode(Output.self, from: Data(latin1.utf8)).transcription

        var lines: [(start: TimeInterval, text: String)] = []
        var bytes: [UInt8] = []
        var start: TimeInterval = 0, end: TimeInterval = 0
        var breakNext = false, afterSegment = false, afterSilence = false, movable = false

        for piece in pieces {
            let from = TimeInterval(piece.offsets.from) / 1000, to = TimeInterval(piece.offsets.to) / 1000
            let text = piece.tokens.filter { !($0.text.hasPrefix("[_") && $0.text.hasSuffix("]")) }
                .flatMap { $0.text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }
            let endsSegment = piece.tokens.contains { $0.text.hasPrefix("[_TT_") }
            defer {
                if endsSegment { breakNext = true; afterSegment = true }
            }
            guard !text.isEmpty else { continue }

            let visible = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let punctuation = visible.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            let mark = visible.unicodeScalars.first.map { [.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory) } ?? false
            let silence = from - end > 1.0
            if bytes.isEmpty {
                start = from
            } else if (breakNext || silence) && !punctuation && !mark && String(bytes: bytes, encoding: .utf8) != nil {
                lines.append((start, String(decoding: bytes, as: UTF8.self)))
                bytes = []
                start = from
                // A new whisper segment right at the edge of a silence is usually the next speech, timed early.
                movable = afterSegment && !afterSilence && !silence
                breakNext = false; afterSegment = false; afterSilence = false
            } else if silence {
                breakNext = true; afterSilence = true
            }
            bytes += text

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
        if !bytes.isEmpty { lines.append((start, String(decoding: bytes, as: UTF8.self))) }
        return lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (line.start, text)
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static func render(_ lines: [Line], title: String, startedAt: Date, seconds: TimeInterval) -> String {
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
