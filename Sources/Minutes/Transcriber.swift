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
    static let language = "th"

    private struct Line {
        let start: TimeInterval
        let speaker: String
        let text: String
    }

    static func transcribe(_ recording: Recording) throws -> URL {
        try transcribe(folder: recording.folder, title: recording.title, startedAt: recording.startedAt)
    }

    static func transcribe(folder: URL, title: String, startedAt: Date) throws -> URL {
        guard let whisper = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { throw TranscriptionError(message: "whisper-cli not found; run setup.sh") }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscriptionError(message: "Speech model missing; run setup.sh")
        }

        var lines: [Line] = []
        let tracks = [("me.wav", "Me"), ("others.wav", "Others")].map { (folder.appendingPathComponent($0.0), $0.1) }
        for (track, speaker) in tracks {
            lines += try transcribe(track, speaker: speaker, whisper: whisper)
        }
        lines.sort { $0.start < $1.start }

        let seconds = tracks.map { audioSeconds($0.0) }.max() ?? 0
        let output = folder.appendingPathComponent("transcript.md")
        try render(lines, title: title, startedAt: startedAt, seconds: seconds).write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    private static func transcribe(_ wav: URL, speaker: String, whisper: String) throws -> [Line] {
        guard audioSeconds(wav) >= 1 else { return [] }

        let base = wav.deletingPathExtension()
        var args = ["-m", model.path, "-f", wav.path, "-l", language, "-osrt", "-of", base.path, "-np"]
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

        let srt = try String(contentsOf: base.appendingPathExtension("srt"), encoding: .utf8)
        return parseSRT(srt).map { Line(start: $0.start, speaker: speaker, text: $0.text) }
    }

    // Tracks are 16 kHz mono 16-bit: 32,000 bytes a second.
    private static func audioSeconds(_ wav: URL) -> TimeInterval {
        TimeInterval((try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 32_000
    }

    static func parseSRT(_ srt: String) -> [(start: TimeInterval, text: String)] {
        srt.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .compactMap { block in
                let rows = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                guard let timing = rows.firstIndex(where: { $0.contains("-->") }),
                      let start = seconds(rows[timing].components(separatedBy: "-->")[0])
                else { return nil }
                let text = rows[(timing + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : (start, text)
            }
    }

    private static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private static func clock(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static func render(_ lines: [Line], title: String, startedAt: Date, seconds: TimeInterval) -> String {
        let date = DateFormatter()
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
