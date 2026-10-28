import Foundation

enum SummaryModel: String, CaseIterable, Codable {
    case sonnet, opus, haiku

    var label: String { rawValue.capitalized }

    private static let key = "summaryModel"

    static var current: SummaryModel {
        get { UserDefaults.standard.string(forKey: key).flatMap(SummaryModel.init(rawValue:)) ?? .sonnet }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

struct SummaryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Summarises transcript.md into summary.md with `claude -p` on the user's Claude subscription.
enum Summarizer {
    static let timeout: TimeInterval = 300
    // Empty on purpose: claude looks for CLAUDE.md from its working directory up.
    static let workDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Minutes/summary-cwd")

    private static let pathKey = "claudePath"
    private static let setPathHint = "defaults write com.enta1234.minutes claudePath /path/to/claude"

    static func claudePath() -> String? {
        let fm = FileManager.default
        // A path set by hand wins and is not second-guessed, so a wrong one shows up as an error.
        if let custom = UserDefaults.standard.string(forKey: pathKey), !custom.isEmpty {
            return fm.isExecutableFile(atPath: custom) ? custom : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let fixed = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let found = fixed.first(where: fm.isExecutableFile(atPath:)) { return found }

        // GUI apps get no shell PATH, so look through nvm's Node versions, newest first.
        let nvm = "\(home)/.nvm/versions/node"
        let versions = ((try? fm.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { versionNumbers($0).lexicographicallyPrecedes(versionNumbers($1)) }
        return versions.reversed().map { "\(nvm)/\($0)/bin/claude" }.first(where: fm.isExecutableFile(atPath:))
    }

    /// Blocking; call off the main thread.
    static func summarize(folder: URL, model: SummaryModel) throws -> URL {
        let transcriptURL = folder.appendingPathComponent("transcript.md")
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            throw SummaryError(message: "No transcript.md in \(folder.lastPathComponent); transcribe the meeting first")
        }
        guard let claude = claudePath() else {
            let custom = UserDefaults.standard.string(forKey: pathKey) ?? ""
            let problem = custom.isEmpty ? "Claude Code CLI not found" : "claudePath \(custom) is not an executable"
            throw SummaryError(message: "\(problem). Set its path with: \(setPathHint)")
        }

        let meta = Workspace.readMeta(folder)
        let title = meta?.title ?? folder.lastPathComponent
        let startedAt = meta?.startedAt ?? Date()
        let input = "Meeting: \(title), \(stamp(startedAt))\n\n\(transcript)"

        let text = try run(claude, model: model, input: input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummaryError(message: "Claude returned an empty summary") }

        // The title can be edited during the run, which renames the folder.
        let folder = meta.flatMap { Workspace.folder(id: $0.id) } ?? folder
        let output = folder.appendingPathComponent("summary.md")
        let page = "# \(Workspace.readMeta(folder)?.title ?? title)\n\n\(stamp(startedAt)) · Summarised by Claude \(model.label)\n\n\(text)\n"
        try page.write(to: output, atomically: true, encoding: .utf8)
        // Folders recorded before meta.json existed still get their summary.
        if meta != nil {
            try Workspace.updateMeta(folder) {
                $0.summaryModel = model.rawValue
                $0.summarizedAt = Date()
            }
        }
        Workspace.notifyChanged()
        return output
    }

    private static func run(_ claude: String, model: SummaryModel, input: String) throws -> String {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        // No --bare: it skips the keychain, so the subscription login would not be used.
        process.arguments = [
            "-p", "--model", model.rawValue,
            "--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--no-session-persistence", "--output-format", "text",
            "--system-prompt", prompt,
        ]
        process.currentDirectoryURL = workDir
        // An npm-installed claude is a `#!/usr/bin/env node` script; node sits beside it, and GUI apps get no shell PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: claude).deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // If claude exits without reading stdin, the write must fail with EPIPE rather than kill the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()

        let errors = Buffer()
        let readers = DispatchGroup()
        DispatchQueue.global().async(group: readers) { errors.data = stderr.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let timedOut = Buffer()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.data = Data([1])
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        readers.wait()

        if !timedOut.data.isEmpty {
            throw SummaryError(message: "Claude did not finish within \(Int(timeout / 60)) minutes")
        }
        guard process.terminationStatus == 0 else {
            let detail = errors.data.isEmpty ? output : errors.data
            let tail = String(decoding: detail.suffix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SummaryError(message: "claude exited with \(process.terminationStatus): \(tail)")
        }
        return String(decoding: output, as: UTF8.self)
    }

    private final class Buffer: @unchecked Sendable {
        var data = Data()
    }

    private static func versionNumbers(_ name: String) -> [Int] {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    static let prompt = """
    You summarise meeting transcripts. The first input line gives the meeting title and date; the rest is an automatic \
    speech-to-text transcript. Each turn starts with a [hh:mm:ss] timestamp and a speaker: "Me" is the person who \
    recorded the meeting, "Others" is everyone else on the call and may be several different people. Speech \
    recognition makes mistakes: work out the meaning from context, never quote garbled or nonsensical text, and leave \
    out anything you cannot understand.

    Write in Thai. Keep product names, people's names and technical terms in their original language. Output exactly \
    the three sections below in this order and nothing else: no preamble, no closing remarks, no other headings.

    ## สรุป
    One or two short paragraphs: what the meeting was about and what came out of it.

    ## สิ่งที่ตัดสินใจ
    A bullet list of the decisions that were actually made.

    ## Action items
    A markdown table with exactly these columns:
    | งาน | ผู้รับผิดชอบ | กำหนด | เวลา |
    - งาน: the task.
    - ผู้รับผิดชอบ: a person's name only if it is said in the transcript; "Me" if the person who recorded took the \
    task; otherwise "ไม่ระบุ". Never guess an owner.
    - กำหนด: the due date or deadline only if one is stated; otherwise "-". Never invent a date.
    - เวลา: the timestamp of the turn where the task was agreed, copied with its brackets, e.g. [00:12:34].

    Use only what the transcript says. If a section has nothing, write "ไม่มี" under its heading.
    """
}
