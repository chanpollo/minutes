import CryptoKit
import Foundation

/// A reply in a comment's thread, from a person or from Claude.
struct CommentMessage: Codable, Equatable, Identifiable {
    var id: String
    var author: String
    var text: String
    var createdAt: Date
    var editedAt: Date?
    var claude: Bool?
    var model: String?
    /// The files Claude changed with this reply and the SHA-256 of each after its title line, so Undo only puts back
    /// files nothing else has changed since.
    var revised: [String: String]?
    var undone: Bool?

    var isClaude: Bool { claude == true }
}

/// 0.6.4–0.6.5 kept Claude's one answer on the comment; read once and turned into a reply.
struct CommentReply: Codable, Equatable {
    var text: String
    var at: Date
    var model: String
    var changed: Bool
    var undone: Bool?
    var revised: [String: String]?
    var revisedHash: String?
}

/// Sends a comment's thread to the summary model with the record it is on, applies the edits it returns and adds its
/// reply to the thread, resolving it when Claude says it is done, as on a shared artifact.
enum CommentRevision {
    struct Answer: Decodable {
        struct Edit: Decodable {
            /// summary.md or transcript.md; the comment's own file when left out.
            var file: String?
            let find: String
            let replace: String
        }
        let reply: String
        let edits: [Edit]?
        let resolve: Bool?
    }

    static func fileName(_ target: CommentTarget) -> String {
        target == .summary ? "summary.md" : "transcript.md"
    }

    /// Why a comment of this meeting cannot go to Claude now; nil when it can.
    static func unavailable(meta: MeetingMeta?) -> String? {
        if Settings.summaryProvider == .off { return "Summaries are off in Settings" }
        if meta?.confidential == true { return "Marked confidential" }
        if let reason = SummaryModel.current.unavailable { return reason }
        return nil
    }

    static let files = ["summary.md", "transcript.md"]

    /// Blocking; call off the main thread. Claude answers the newest message of the thread and may change the summary
    /// and the transcript both, so a correction made on one reaches the other.
    static func revise(meetingID: String, commentID: String, model: SummaryModel, cancel: Summarizer.ClaudeCancel) throws {
        guard let folder = Workspace.folder(id: meetingID),
              let comment = CommentFile.read(folder).first(where: { $0.id == commentID }) else {
            throw SummaryError(message: "The comment is gone")
        }
        let meta = Workspace.readMeta(folder)
        if let reason = unavailable(meta: meta) { throw SummaryError(message: reason) }
        let target = fileName(comment.target)
        guard documents(in: folder)[target] != nil else { throw SummaryError(message: "No \(target) to revise") }
        let input = self.input(comment, title: meta?.title ?? folder.lastPathComponent, documents: documents(in: folder))

        let raw = try Summarizer.run(model: model, system: prompt(comment.target), input: input, cancel: cancel)
        let answer = try parse(raw)
        let reply = answer.reply.trimmingCharacters(in: .whitespacesAndNewlines)

        // The title can be edited, renaming the folder, while Claude runs.
        guard let current = Workspace.folder(id: meetingID) else { throw SummaryError(message: "The meeting is gone") }
        let now = documents(in: current)
        let changed = try apply(answer.edits ?? [], to: now, default: target).filter { now[$0.key] != $0.value }
        var message = CommentMessage(id: UUID().uuidString, author: model.provider.name, text: reply.isEmpty ? "No change." : reply,
                                     createdAt: Date(), claude: true, model: model.rawValue)
        if !changed.isEmpty {
            try FileManager.default.createDirectory(at: revisionsFolder(current), withIntermediateDirectories: true)
            for (name, text) in changed {
                try now[name]!.write(to: savedURL(message.id, name, in: current), atomically: true, encoding: .utf8)
                try text.write(to: current.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            message.revised = changed.mapValues(hash)
        }
        try CommentFile.update(current) { list in
            guard let index = list.firstIndex(where: { $0.id == commentID }) else { return }
            list[index].replies = (list[index].replies ?? []) + [message]
            // A resolved thread stays resolved; Claude answers in it.
            if answer.resolve == true, list[index].resolvedAt == nil {
                list[index].resolvedAt = Date()
                list[index].resolvedBy = model.provider.name
            }
        }
        Workspace.notifyChanged()
    }

    /// Puts the files back as they were before that reply of Claude's, when nothing else changed them since.
    static func undo(meetingID: String, commentID: String, messageID: String) throws {
        guard let folder = Workspace.folder(id: meetingID),
              let message = CommentFile.read(folder).first(where: { $0.id == commentID })?.replies?.first(where: { $0.id == messageID }),
              message.undone != true else { return }
        var restored: [String: String] = [:]
        for (name, revised) in message.revised ?? [:] {
            guard let now = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                  let before = savedText(messageID, name, in: folder) else {
                throw SummaryError(message: "The earlier text was not kept")
            }
            guard hash(now) == revised else { throw SummaryError(message: "The text has changed since Claude revised it") }
            // A rename since rewrote the title line; keep the current one.
            restored[name] = titleLine(now) + body(before)
        }
        guard !restored.isEmpty else { return }
        for (name, text) in restored {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        removeSaved(messageID, in: folder)
        try CommentFile.update(folder) { list in
            guard let index = list.firstIndex(where: { $0.id == commentID }),
                  let reply = list[index].replies?.firstIndex(where: { $0.id == messageID }) else { return }
            list[index].replies?[reply].undone = true
        }
        Workspace.notifyChanged()
    }

    static func canUndo(_ message: CommentMessage, folder: URL?) -> Bool {
        guard let folder, message.undone != true, let revised = message.revised, !revised.isEmpty else { return false }
        return revised.allSatisfy { name, hash in
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)).map(self.hash) == hash
        }
    }

    static func documents(in folder: URL) -> [String: String] {
        var documents: [String: String] = [:]
        for name in files {
            documents[name] = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        return documents
    }

    private static func savedURL(_ messageID: String, _ name: String, in folder: URL) -> URL {
        revisionsFolder(folder).appendingPathComponent("\(messageID)-\(name)")
    }

    /// 0.6.4 kept one file as <comment id>.md; a reply made from that answer keeps the comment's id.
    private static func savedText(_ messageID: String, _ name: String, in folder: URL) -> String? {
        (try? String(contentsOf: savedURL(messageID, name, in: folder), encoding: .utf8))
            ?? (try? String(contentsOf: revisionsFolder(folder).appendingPathComponent("\(messageID).md"), encoding: .utf8))
    }

    /// The text kept for Undo of one of Claude's replies, gone with it.
    static func removeSaved(_ messageID: String, in folder: URL) {
        for name in files + [""] {
            let url = name.isEmpty ? revisionsFolder(folder).appendingPathComponent("\(messageID).md") : savedURL(messageID, name, in: folder)
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func revisionsFolder(_ folder: URL) -> URL {
        folder.appendingPathComponent("revisions", isDirectory: true)
    }

    // MARK: Edits

    /// Each `find` must be in its file exactly once. Title lines stay, and a transcript keeps every turn's time and
    /// speaker. Returns every file, changed or not.
    static func apply(_ edits: [Answer.Edit], to documents: [String: String], default file: String) throws -> [String: String] {
        var revised = documents
        for edit in edits where edit.find != edit.replace {
            let name = edit.file ?? file
            guard var text = revised[name] else { throw SummaryError(message: "Claude changed a file the meeting does not have") }
            guard !edit.find.isEmpty, let range = text.range(of: edit.find) else {
                throw SummaryError(message: "Claude's change did not match the text")
            }
            guard text.range(of: edit.find, range: text.index(after: range.lowerBound)..<text.endIndex) == nil else {
                throw SummaryError(message: "Claude's change matched more than one place")
            }
            text.replaceSubrange(range, with: edit.replace)
            revised[name] = text
        }
        for (name, text) in revised where text != documents[name] {
            let before = documents[name]!
            guard titleLine(text) == titleLine(before) else { throw SummaryError(message: "Claude changed the title line") }
            if name == "transcript.md" {
                let turns = { (t: String) in TranscriptParser.parse(t).map { "\($0.time) \($0.speaker)" } }
                guard turns(text) == turns(before) else { throw SummaryError(message: "Claude changed the transcript's turns") }
            } else if body(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SummaryError(message: "Claude returned an empty summary")
            }
        }
        return revised
    }

    static func parse(_ raw: String) throws -> Answer {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(raw[start...end].utf8)) else {
            throw SummaryError(message: "Claude's answer could not be read")
        }
        return answer
    }

    private static func titleLine(_ text: String) -> String {
        text.firstIndex(of: "\n").map { String(text[...$0]) } ?? text
    }

    private static func body(_ text: String) -> String {
        text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? ""
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(body(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Prompt

    static func input(_ comment: MeetingComment, title: String, documents: [String: String]) -> String {
        let time = comment.lineTime.map { "Transcript time: \(MeetingFormat.longClock($0))\n" } ?? ""
        let blocks = files.compactMap { name in documents[name].map { "<file name=\"\(name)\">\n\($0)\n</file>" } }
        let thread = ([(comment.author, comment.text, comment.createdAt)] + (comment.replies ?? []).map { ($0.author, $0.text, $0.createdAt) })
            .map { "<message from=\"\($0.0)\" at=\"\(MeetingFormat.stamp($0.2))\">\n\($0.1)\n</message>" }
        return """
            Meeting: \(title)

            \(blocks.joined(separator: "\n\n"))

            The comment thread is on \(fileName(comment.target)), on this passage:
            <quote>\(comment.quote)</quote>
            Text around it: …\(comment.prefix)[\(comment.quote)]\(comment.suffix)…
            \(time)The thread, oldest first:
            \(thread.joined(separator: "\n"))
            """
    }

    static func prompt(_ target: CommentTarget) -> String {
        """
        You revise a meeting record after a reader commented on it. The input gives the record's files: summary.md, \
        the meeting summary in markdown (when there is one yet), and transcript.md, the automatic speech-to-text \
        transcript with one **[hh:mm:ss] Speaker:** turn per paragraph. Then the passage the comment is on, in \
        \(fileName(target)), with the text around it, and the comment thread: the reader's comment and any replies, \
        "Claude", "Codex", "Gemini" or "Ollama" being you. Your earlier edits are already in the files. Answer the newest message.

        Work out what it asks for. When it asks for a change (a correction, rewording, something missing, \
        wrong or to be removed), make the smallest change that does it, everywhere in the record the same point \
        appears, so the summary and the transcript agree:
        - A word or name the speech recognition got wrong is fixed in the transcript and wherever the summary has it.
        - Anything else the summary says wrongly is fixed in the summary; the transcript keeps what was said.
        When it asks a question or makes a note, answer it and change nothing, unless the answer shows the record is \
        wrong.

        In summary.md keep the three section headings, the action items table with its columns and one row per task, \
        and any ![](frames/…) picture lines; use only what the transcript supports and never invent a name, date, \
        decision or task. In transcript.md change only the spoken words after a turn's marker; never change a \
        timestamp or speaker label, and never join, split, add or remove turns. Never change a file's first line (the \
        title).

        Output only one JSON object and nothing else:
        {"reply": "...", "edits": [{"file": "summary.md", "find": "...", "replace": "..."}], "resolve": true}
        - reply: one or two short sentences to the reader, in the language of the comment: what you changed and \
        where, or the answer and why nothing changed. No greeting.
        - edits: file is summary.md or transcript.md; find is text copied exactly from that file, long enough to occur \
        only once in it; replace is what it becomes. Fix each place with its own edit. An empty list when nothing \
        changes.
        - resolve: true only when the newest message asks for a change and you made it, or it asks for one that is \
        already there. false when it is a question or a remark you answered, or when you ask the reader something \
        back: the reader reads your reply and resolves the thread.
        """
    }
}
