import Foundation

struct SummaryError: LocalizedError {
    enum Reason { case failed, off, confidential }
    let message: String
    var reason = Reason.failed
    var errorDescription: String? { message }
}

/// Summarises transcript.md into summary.md with the provider chosen in Settings: `claude -p` on the user's Claude
/// subscription, `codex exec` on their ChatGPT one, or a model in Ollama on this Mac.
enum Summarizer {
    // Empty on purpose: claude and codex look for CLAUDE.md and AGENTS.md from their working directory up.
    static let workDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Minutes/summary-cwd")

    private static let pathKey = "claudePath"
    private static let setPathHint = "defaults write com.enta1234.minutes claudePath /path/to/claude"

    static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CLITool.find("claude", customKey: pathKey, extra: ["\(home)/.claude/local/claude"])
    }

    /// Blocking; call off the main thread. `force` sends a meeting marked confidential anyway; only an explicit request
    /// for that meeting sets it. Summaries switched off in Settings are never sent. `followRenames` finds the meeting
    /// again by id in the workspace; the command line passes false so it only ever writes to the folder it was given.
    static func summarize(
        folder: URL, model: SummaryModel, force: Bool = false, followRenames: Bool = true,
        calendar: (MeetingMeta) -> [CalendarEvent] = { CalendarTitle.on(appBundleID: $0.bundleID, voice: $0.recordMode == .voice, at: $0.startedAt) }
    ) throws -> URL {
        guard Settings.summaryProvider != .off else {
            throw SummaryError(message: "Summaries are off. Choose a provider under Summary in Settings.", reason: .off)
        }
        if !force, Workspace.readMeta(folder)?.confidential == true {
            throw SummaryError(message: "Marked confidential, so it was not sent for summary.", reason: .confidential)
        }
        let transcriptURL = folder.appendingPathComponent("transcript.md")
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            throw SummaryError(message: "No transcript.md in \(folder.lastPathComponent); transcribe the meeting first")
        }
        if model.provider == .claude, claudePath() == nil {
            let custom = UserDefaults.standard.string(forKey: pathKey) ?? ""
            let problem = custom.isEmpty ? "Claude Code CLI not found" : "claudePath \(custom) is not an executable"
            throw SummaryError(message: "\(problem). Set its path with: \(setPathHint)")
        }

        let meta = Workspace.readMeta(folder)
        let title = meta?.title ?? folder.lastPathComponent
        let startedAt = meta?.startedAt ?? Date()
        // Meetings booked over each other: the model says which one was recorded. The command line never renames.
        let events = followRenames && Settings.titleFromCalendar
            ? meta.map { choosableEvents($0, calendar($0)) } ?? []
            : []
        let invited = events.isEmpty
            ? meta?.attendees.flatMap { $0.isEmpty ? nil : "Invited: \($0.joined(separator: ", "))\n" } ?? ""
            : eventList(events)
        let frames = FrameExtractor.shared.prepare(folder: folder, meetingID: followRenames ? meta?.id : nil)
        let pictures = Frames.promptList(frames)
        let input = "Meeting: \(title), \(stamp(startedAt))\n\(invited)\n\(transcript)" + (pictures.isEmpty ? "" : "\n\n\(pictures)")

        let raw = try run(model: model, system: prompt(Settings.summaryLanguage, pictures: !pictures.isEmpty,
                                                               voice: meta?.recordMode == .voice, events: !events.isEmpty), input: input)
        let (picked, reply) = chosenEvent(raw, count: events.count)
        let text = Frames.keepKnown(reply, known: Set(frames.map(\.file)), limit: 6).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummaryError(message: "\(model.label) returned an empty summary") }

        // The title can be edited during the run, which renames the folder.
        var folder = followRenames ? meta.flatMap { Workspace.folder(id: $0.id) } ?? folder : folder
        // Not when the title was edited while the model ran.
        if let picked, Workspace.readMeta(folder)?.title == title, events[picked].title != title {
            folder = try useEvent(events[picked], for: folder, byHand: false)
        }
        let output = folder.appendingPathComponent("summary.md")
        let page = "# \(Workspace.readMeta(folder)?.title ?? title)\n\n\(stamp(startedAt)) · Summarised by \(model.label)\n\n\(text)\n"
        try page.write(to: output, atomically: true, encoding: .utf8)
        CommentFile.refreshMarkdown(folder)
        // Folders recorded before meta.json existed still get their summary.
        if meta != nil {
            try Workspace.updateMeta(folder) {
                $0.summaryModel = model.rawValue
                $0.summarizedAt = Date()
                $0.sentAnyway = force && $0.confidential == true ? true : nil
            }
        }
        Workspace.notifyChanged()
        return output
    }

    /// The events to choose between: only when two or more were on at the start, the title is still one of them (not
    /// typed by hand) and the event was not picked by hand in the window.
    static func choosableEvents(_ meta: MeetingMeta, _ events: [CalendarEvent]) -> [CalendarEvent] {
        guard meta.note != true, meta.eventPicked != true, events.count > 1,
              events.contains(where: { $0.title == meta.title }) else { return [] }
        // The current one first, so "keep it" is always 1.
        return events.filter { $0.title == meta.title } + events.filter { $0.title != meta.title }
    }

    /// Names the meeting after `event` and takes its invitees; `byHand` (the window's menu) keeps later summaries from
    /// choosing again. Returns the renamed folder.
    @discardableResult
    static func useEvent(_ event: CalendarEvent, for folder: URL, byHand: Bool) throws -> URL {
        let renamed = try Workspace.rename(folder, to: event.title)
        try Workspace.updateMeta(renamed) {
            $0.attendees = event.attendees.isEmpty ? nil : event.attendees
            if byHand { $0.eventPicked = true }
            if Settings.confidentialExternal, event.hasExternal { $0.confidential = true }
        }
        Workspace.notifyChanged()
        return renamed
    }

    static func eventList(_ events: [CalendarEvent]) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let lines = events.enumerated().map { i, event in
            let invited = event.attendees.isEmpty ? "" : " · Invited: \(event.attendees.joined(separator: ", "))"
            return "\(i + 1). \(event.title) (\(time.string(from: event.start))–\(time.string(from: event.end)))\(invited)"
        }
        return "Calendar events on when the recording began:\n" + lines.joined(separator: "\n") + "\n"
    }

    /// The index Claude chose on its `Event:` first line, when it is not the first (the current title), and the reply
    /// without that line. A reply with no such line is kept whole.
    static func chosenEvent(_ reply: String, count: Int) -> (Int?, String) {
        guard count > 1 else { return (nil, reply) }
        let trimmed = reply.drop { $0.isWhitespace || $0.isNewline }
        let end = trimmed.firstIndex(where: \.isNewline) ?? trimmed.endIndex
        let line = trimmed[..<end].trimmingCharacters(in: .whitespaces)
        guard line.lowercased().hasPrefix("event:") else { return (nil, reply) }
        let value = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
        let rest = String(trimmed[end...])
        guard let n = Int(value), n >= 1, n <= count, n != 1 else { return (nil, rest) }
        return (n - 1, rest)
    }

    /// The one way Minutes calls a model: no tools, no MCP, no settings files, no session kept. `cancel` stops it early.
    static func run(model: SummaryModel, system: String, input: String, cancel: ClaudeCancel? = nil) throws -> String {
        if let reason = model.unavailable { throw SummaryError(message: reason) }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        switch model.provider {
        case .claude:
            // No --bare: it skips the keychain, so the subscription login would not be used.
            let arguments = [
                "-p", "--model", model.name,
                "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                "--no-session-persistence", "--output-format", "text",
                "--system-prompt", system,
            ]
            let result = try CLITool.run(claudePath()!, arguments: arguments, input: input, directory: workDir,
                                         timeout: model.timeout, name: "Claude", cancel: cancel)
            guard result.status == 0 else { throw SummaryError(message: "claude exited with \(result.status): \(result.errorTail)") }
            return String(decoding: result.output, as: UTF8.self)
        case .codex:
            return try CodexEngine.run(model: model.name, system: system, input: input, directory: workDir,
                                       timeout: model.timeout, cancel: cancel)
        case .agy:
            return try AgyEngine.run(model: model.name, system: system, input: input, directory: workDir,
                                     timeout: model.timeout, cancel: cancel)
        case .ollama:
            return try OllamaEngine.run(model: model.name, system: system, input: input, timeout: model.timeout, cancel: cancel)
        }
    }

    /// Stops a running model call from another thread; one made before the call starts stops it as it starts.
    final class ClaudeCancel: @unchecked Sendable {
        private let lock = NSLock()
        private var stop: (() -> Void)?
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func attach(_ process: Process) {
            attach { if process.isRunning { process.terminate() } }
        }

        func attach(_ stop: @escaping () -> Void) {
            let now = lock.withLock { () -> Bool in
                self.stop = stop
                return cancelled
            }
            if now { stop() }
        }

        func cancel() {
            let running = lock.withLock { () -> (() -> Void)? in
                cancelled = true
                return stop
            }
            running?()
        }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private struct Wording {
        let summary, decisions, actions, task, owner, due, time, none, unnamed: String
    }

    private static let thai = Wording(
        summary: "สรุป", decisions: "สิ่งที่ตัดสินใจ", actions: "Action items", task: "งาน", owner: "ผู้รับผิดชอบ",
        due: "กำหนด", time: "เวลา", none: "ไม่มี", unnamed: "ไม่ระบุ")
    private static let english = Wording(
        summary: "Summary", decisions: "Decisions", actions: "Action items", task: "Task", owner: "Owner",
        due: "Due", time: "Time", none: "None", unnamed: "Not stated")

    /// `pictures` adds the rules for placing frames from the video, `voice` what the mic's labels mean then; without
    /// them the prompt is what it always was.
    static func prompt(_ language: Settings.SummaryLanguage, pictures: Bool = false, voice: Bool = false, events: Bool = false) -> String {
        let intro = """
        You summarise meeting transcripts. The first input line gives the meeting title and date; the rest is an automatic \
        speech-to-text transcript. Each turn starts with a [hh:mm:ss] timestamp and a speaker: "Me" is the person who \
        recorded the meeting. "Others" is everyone else on the call when their voices were not separated, and may be \
        several different people. "Speaker 1", "Speaker 2" and so on are different voices among the others, told apart \
        automatically: a label can be wrong, one person can appear under two labels, and they are not names. Any other \
        label is a name the user typed in place of one of these. Speech recognition makes mistakes: work out the meaning \
        from context, never quote garbled or nonsensical text, and leave out anything you cannot understand.
        """ + (voice ? """
         This meeting was recorded in Voice mode: the microphone may have picked up several people. When its voices \
        were told apart, the "Speaker" labels also include the person who recorded, so "Me" may not appear at all; \
        when they were not, "Me" is everyone near the microphone.
        """ : "") + """


        An "Invited:" line may follow the first line with the names on the calendar invitation. The invited list only \
        helps you spell names heard in the transcript; it never makes someone an owner or attendee by itself.


        """ + (events ? eventsNote : "") + (pictures ? picturesNote : "")
        let rules = """
        Keep product names, people's names and technical terms in their original language. \
        \(events ? "After the Event line, output" : "Output") exactly the three \
        sections below in this order and nothing else: no preamble, no closing remarks, no other headings.
        """
        switch language {
        case .thai:
            return intro + "Write in Thai. " + rules + "\n\n" + sections(thai)
        case .english:
            return intro + "Write in English. " + rules + "\n\n" + sections(english)
        case .meeting:
            return intro + """
            Write in the language most of the meeting was spoken in. \(rules) When that language is Thai, use the Thai \
            headings and words below; otherwise use the English ones from the second copy, with the text in the \
            meeting's language.

            \(sections(thai))

            Second copy, for any other language:

            \(sections(english))
            """
        }
    }

    private static let eventsNote = """
        Instead of an "Invited:" line, a numbered list of calendar events may follow the first line: several meetings \
        were booked when the recording began, and the title was taken from event 1 as a guess. Decide from what is \
        actually discussed which event this conversation is, by its title and the names heard. Event 1 is only a \
        guess: when the talk is not about event 1's subject and another event fits better, even loosely by its title, \
        choose that one; keep 1 when the talk is about event 1's subject or no other event fits better. Write your \
        choice as the very first line of your output, exactly "Event: <number>". Use only that event's invited names \
        to spell names, and never mention the events, the guess or a mismatch between the title and the talk in the \
        summary.


        """

    private static let picturesNote = """
        After the transcript comes a list of pictures taken from the meeting's screen video, mostly slides and shared \
        screens: each with its [hh:mm:ss] time, its file name and the text read from it, which can have mistakes. You \
        may put up to 6 of these pictures in the summary. Place a picture only where it clearly shows what a summary \
        paragraph or decision is about, judged by its text and its time against the transcript; when in doubt, leave it \
        out, and use none if none fit. Each picture goes on its own line right after the one paragraph or decision \
        bullet it shows and before the next one, never gathered at the end of a section, written exactly as \
        ![](frames/hh-mm-ss.jpg) with the file name as listed. Under a bullet, indent it by two spaces, like this:
        - <the decision the picture shows>
          ![](frames/00-18-50.jpg)
        - <the next decision>
        In the summary section likewise: a paragraph, the picture line it goes with, an empty line, the next paragraph. \
        Use each picture at most once, never inside the action items table, and never mention the pictures in the text.


        """

    private static func sections(_ w: Wording) -> String {
        """
        ## \(w.summary)
        One or two short paragraphs: what the meeting was about and what came out of it.

        ## \(w.decisions)
        A bullet list of the decisions that were actually made.

        ## \(w.actions)
        A markdown table with exactly these columns:
        | \(w.task) | \(w.owner) | \(w.due) | \(w.time) |
        - \(w.task): the task.
        - \(w.owner): a person's name only if it is said in the transcript; "Me" if the person who recorded took the \
        task; otherwise "\(w.unnamed)". Never guess an owner.
        - \(w.due): the due date or deadline only if one is stated; otherwise "-". Never invent a date.
        - \(w.time): the timestamp of the turn where the task was agreed, copied with its brackets, e.g. [00:12:34].

        Use only what the transcript says. If a section has nothing, write "\(w.none)" under its heading.
        """
    }

    /// What the "Summary ready" card says about summary.md: counts and the first action item.
    struct Digest: Equatable {
        var decisions = 0
        var actions = 0
        /// "task — owner, due", leaving out an unnamed owner and a missing date.
        var firstAction: String?
    }

    /// Reads the sections by position (summary, decisions, action items), so it works in any summary language.
    static func digest(_ markdown: String) -> Digest {
        var digest = Digest()
        var section = -1
        var tableRows: [[String]] = []
        let empty: Set<String> = [thai.none, english.none, thai.unnamed, english.unnamed, "-", "—", ""]
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { section += 1; continue }
            switch section {
            case 1 where line.hasPrefix("- ") || line.hasPrefix("* "):
                if !empty.contains(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)) { digest.decisions += 1 }
            case 2 where line.hasPrefix("|"):
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { continue }
                tableRows.append(cells)
            default: break
            }
        }
        // The first row is the header.
        let items = tableRows.dropFirst().filter { !($0.first.map(empty.contains) ?? true) }
        digest.actions = items.count
        if let first = items.first {
            // The due date wraps as one unit, so "พฤ. 29 ต.ค." is not split across lines.
            let due = first.count > 2 ? first[2].replacingOccurrences(of: " ", with: "\u{00A0}") : ""
            let extras = [first.count > 1 ? first[1] : "", due].filter { !empty.contains($0) }
            digest.firstAction = first[0] + (extras.isEmpty ? "" : " — " + extras.joined(separator: ", "))
        }
        return digest
    }
}
