import AppKit
import SwiftUI

enum CommentTarget: String, Codable {
    case summary, transcript
}

/// One entry of comments.json in the meeting folder.
struct MeetingComment: Codable, Equatable, Identifiable {
    var id: String
    var target: CommentTarget
    var quote: String
    /// About 32 characters each side of the quote, to find it again after the text changes.
    var prefix: String
    var suffix: String
    /// The transcript line's time, in seconds.
    var lineTime: TimeInterval?
    var text: String
    var author: String
    var createdAt: Date
    var editedAt: Date?
    /// The thread after the comment: people's replies and Claude's.
    var replies: [CommentMessage]?
    /// Resolved: no highlight, listed under Resolved until it is reopened.
    var resolvedAt: Date?
    /// "Claude", or the name of the person who resolved it.
    var resolvedBy: String?
    /// Read from 0.6.4–0.6.5 files only; becomes a reply.
    var reply: CommentReply?

    /// Claude's one answer of 0.6.4–0.6.5, as a reply in the thread.
    func migrated() -> MeetingComment {
        guard let old = reply else { return self }
        var comment = self
        comment.reply = nil
        let revised = old.revised ?? old.revisedHash.map { [CommentRevision.fileName(target): $0] }
        // The comment's id, under which 0.6.4 kept the text before the edit.
        comment.replies = [CommentMessage(id: id, author: "Claude", text: old.text, createdAt: old.at, claude: true,
                                          model: old.model, revised: old.changed ? revised : nil, undone: old.undone)] + (replies ?? [])
        return comment
    }
}

/// Where a comment's quote sits now: a summary block or transcript line, and the range in its text.
struct CommentAnchor: Equatable {
    let unit: Int
    let range: NSRange
}

/// The commentable text of the summary (one unit per heading, paragraph or bullet; tables have none) or the
/// transcript (one unit per line), as the notes window shows it.
struct CommentDocument {
    let target: CommentTarget
    let units: [String?]
    var times: [TimeInterval] = []

    /// The units joined by newlines, for the context around a quote.
    let full: NSString
    private let starts: [Int]

    init(target: CommentTarget, units: [String?], times: [TimeInterval] = []) {
        self.target = target
        self.units = units
        self.times = times
        var starts: [Int] = []
        var offset = 0
        for unit in units {
            starts.append(offset)
            offset += (unit as NSString?)?.length ?? 0
            offset += 1
        }
        self.starts = starts
        full = units.map { $0 ?? "" }.joined(separator: "\n") as NSString
    }

    static func summary(_ blocks: [SummaryBlock]) -> CommentDocument {
        CommentDocument(target: .summary, units: blocks.map { block in
            switch block {
            case .heading(let text): return InlineText.attributed(text, style: .heading).string
            case .paragraph(let text), .bullet(let text, _): return InlineText.attributed(text, style: .summary).string
            case .table, .picture: return nil
            }
        })
    }

    static func summary(markdown: String) -> CommentDocument {
        summary(SummaryMarkdown.parse(markdown))
    }

    static func transcript(_ lines: [TranscriptLine]) -> CommentDocument {
        CommentDocument(target: .transcript, units: lines.map(\.text), times: lines.map(\.time))
    }

    func start(of unit: Int) -> Int { starts[unit] }

    /// The unit holding `location` of `full`, when the whole range stays inside it.
    func unit(containing range: NSRange) -> Int? {
        guard let index = starts.lastIndex(where: { $0 <= range.location }), let text = units[index] else { return nil }
        return NSMaxRange(range) <= starts[index] + (text as NSString).length ? index : nil
    }

    func context(unit: Int, range: NSRange) -> (prefix: String, suffix: String) {
        let start = starts[unit] + range.location
        let end = start + range.length
        let before = full.rangeOfComposedCharacterSequences(for: NSRange(location: max(0, start - 32), length: start - max(0, start - 32)))
        let after = full.rangeOfComposedCharacterSequences(for: NSRange(location: end, length: min(full.length, end + 32) - end))
        let clippedBefore = NSRange(location: before.location, length: start - before.location)
        let clippedAfter = NSRange(location: end, length: min(NSMaxRange(after), full.length) - end)
        return (full.substring(with: clippedBefore), full.substring(with: clippedAfter))
    }
}

enum CommentAnchoring {
    /// The quote where its context matches best; failing that, the text now between its old context.
    static func anchor(_ comment: MeetingComment, in document: CommentDocument) -> CommentAnchor? {
        let full = document.full
        let quote = comment.quote as NSString
        guard quote.length > 0 else { return nil }
        let lineOfTime = comment.lineTime.flatMap { time in document.times.firstIndex { abs($0 - time) < 0.5 } }
        var best: (score: Int, anchor: CommentAnchor)?
        let prefixLength = (comment.prefix as NSString).length, suffixLength = (comment.suffix as NSString).length
        var search = NSRange(location: 0, length: full.length)
        while true {
            let found = full.range(of: comment.quote, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            if let unit = document.unit(containing: found) {
                // Only as much text as the stored context, so a common word does not copy the document each time.
                let before = min(found.location, prefixLength)
                let after = min(full.length - NSMaxRange(found), suffixLength)
                var score = commonSuffix(full.substring(with: NSRange(location: found.location - before, length: before)), comment.prefix)
                    + commonPrefix(full.substring(with: NSRange(location: NSMaxRange(found), length: after)), comment.suffix)
                if unit == lineOfTime { score += 1000 }
                let anchor = CommentAnchor(unit: unit, range: NSRange(location: found.location - document.start(of: unit), length: found.length))
                if best == nil || score > best!.score { best = (score, anchor) }
            }
            let next = found.location + 1
            guard next < full.length else { break }
            search = NSRange(location: next, length: full.length - next)
        }
        if let best { return best.anchor }
        return bracketed(comment, in: document)
    }

    /// The quote was reworded: the end of its prefix and the start of its suffix are still there, close together.
    private static func bracketed(_ comment: MeetingComment, in document: CommentDocument) -> CommentAnchor? {
        let prefix = comment.prefix as NSString, suffix = comment.suffix as NSString
        guard prefix.length >= 8, suffix.length >= 8 else { return nil }
        let head = prefix.substring(from: prefix.length - min(16, prefix.length))
        let tail = suffix.substring(to: min(16, suffix.length))
        let full = document.full
        let longest = max((comment.quote as NSString).length * 2, (comment.quote as NSString).length + 40)
        var search = NSRange(location: 0, length: full.length)
        while true {
            let left = full.range(of: head, options: .literal, range: search)
            guard left.location != NSNotFound else { return nil }
            let from = NSMaxRange(left)
            let window = NSRange(location: from, length: min(full.length - from, longest + tail.count))
            let right = full.range(of: tail, options: .literal, range: window)
            if right.location != NSNotFound, right.location > from {
                let between = trimmed(NSRange(location: from, length: right.location - from), in: full)
                if between.length > 0, let unit = document.unit(containing: between) {
                    return CommentAnchor(unit: unit, range: NSRange(location: between.location - document.start(of: unit), length: between.length))
                }
            }
            search = NSRange(location: left.location + 1, length: full.length - left.location - 1)
            if search.length <= 0 { return nil }
        }
    }

    /// `range` without white space at either end.
    static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        let blank = CharacterSet.whitespacesAndNewlines
        while start < end, let scalar = UnicodeScalar(text.character(at: start)), blank.contains(scalar) { start += 1 }
        while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)), blank.contains(scalar) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func commonSuffix(_ a: String, _ b: String) -> Int {
        zip(a.utf16.reversed(), b.utf16.reversed()).prefix { $0 == $1 }.count
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a.utf16, b.utf16).prefix { $0 == $1 }.count
    }
}

/// comments.json and the comments.md made from it.
enum CommentFile {
    static let name = "comments.json"
    static let markdownName = "comments.md"
    private static let lock = NSLock()

    static func read(_ folder: URL) -> [MeetingComment] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return [] }
        return ((try? decoder.decode([MeetingComment].self, from: data)) ?? []).map { $0.migrated() }
    }

    /// Read-modify-write under one lock, then comments.md again.
    @discardableResult
    static func update(_ folder: URL, _ change: (inout [MeetingComment]) -> Void) throws -> [MeetingComment] {
        lock.lock()
        defer { lock.unlock() }
        var comments = read(folder)
        change(&comments)
        try encoder.encode(comments).write(to: folder.appendingPathComponent(name), options: .atomic)
        let title = Workspace.readMeta(folder)?.title ?? folder.lastPathComponent
        try markdown(comments, title: title, folder: folder)
            .write(to: folder.appendingPathComponent(markdownName), atomically: true, encoding: .utf8)
        return comments
    }

    /// comments.md again after the summary, transcript or title changed, so the synced copy matches the app.
    static func refreshMarkdown(_ folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else { return }
        let title = Workspace.readMeta(folder)?.title ?? folder.lastPathComponent
        try? markdown(read(folder), title: title, folder: folder)
            .write(to: folder.appendingPathComponent(markdownName), atomically: true, encoding: .utf8)
    }

    static func documents(in folder: URL) -> (summary: CommentDocument?, transcript: CommentDocument?) {
        let read = { (name: String) in try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }
        return (read("summary.md").map(CommentDocument.summary(markdown:)),
                read("transcript.md").map { CommentDocument.transcript(TranscriptParser.parse($0)) })
    }

    /// The human-readable copy that goes to Drive with the other text files.
    static func markdown(_ comments: [MeetingComment], title: String, folder: URL) -> String {
        let docs = documents(in: folder)
        return "# Comments · \(title)\n\n" + section(comments, summary: docs.summary, transcript: docs.transcript, level: 2)
    }

    /// Comments under "On the summary", "On the transcript" and "Comments on earlier text" headings at `level`.
    static func section(_ comments: [MeetingComment], summary: CommentDocument?, transcript: CommentDocument?, level: Int) -> String {
        let hashes = String(repeating: "#", count: level)
        var placed: [CommentTarget: [(CommentAnchor, MeetingComment)]] = [:]
        var earlier: [MeetingComment] = []
        for comment in comments where comment.resolvedAt == nil {
            let document = comment.target == .summary ? summary : transcript
            if let document, let anchor = CommentAnchoring.anchor(comment, in: document) {
                placed[comment.target, default: []].append((anchor, comment))
            } else {
                earlier.append(comment)
            }
        }
        var parts: [String] = []
        for (target, heading) in [(CommentTarget.summary, "On the summary"), (.transcript, "On the transcript")] {
            let list = (placed[target] ?? []).sorted { ($0.0.unit, $0.0.range.location) < ($1.0.unit, $1.0.range.location) }
            guard !list.isEmpty else { continue }
            parts.append("\(hashes) \(heading)")
            parts += list.map { entry($0.1) }
        }
        if !earlier.isEmpty {
            parts.append("\(hashes) Comments on earlier text")
            parts += earlier.sorted { $0.createdAt < $1.createdAt }.map { entry($0) }
        }
        let resolved = comments.filter { $0.resolvedAt != nil }
        if !resolved.isEmpty {
            parts.append("\(hashes) Resolved")
            parts += resolved.sorted { $0.createdAt < $1.createdAt }.map { entry($0) }
        }
        return parts.joined(separator: "\n\n") + (parts.isEmpty ? "" : "\n")
    }

    private static func entry(_ comment: MeetingComment) -> String {
        let time = comment.lineTime.map { "[\(MeetingFormat.longClock($0))] " } ?? ""
        let quote = (time + comment.quote).components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        let edited = comment.editedAt == nil ? "" : " (edited)"
        let replies = (comment.replies ?? []).map { reply in
            let note = reply.undone == true ? " (undone)" : reply.editedAt == nil ? "" : " (edited)"
            return "\n\n\(reply.text)\n\n*\(reply.author) · \(MeetingFormat.stamp(reply.createdAt))\(note)*"
        }.joined()
        let resolved = comment.resolvedAt.map { "\n\n*Resolved by \(comment.resolvedBy ?? "someone") · \(MeetingFormat.stamp($0))*" } ?? ""
        return "\(quote)\n\n\(comment.text)\n\n*\(comment.author) · \(MeetingFormat.stamp(comment.createdAt))\(edited)*\(replies)\(resolved)"
    }

    /// The comment texts, for search.
    static func searchText(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url), let comments = try? decoder.decode([MeetingComment].self, from: data) else { return "" }
        return comments.map { $0.migrated() }.flatMap { [$0.text] + ($0.replies ?? []).map(\.text) }.joined(separator: "\n")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// The selected meeting's comments, the composer and which comment is in focus; one per notes window.
final class CommentsModel: ObservableObject {
    enum Side: String { case comments, notes }

    struct Draft: Equatable {
        /// The comment being edited; nil for a new one.
        var editing: String?
        var target: CommentTarget
        var unit: Int
        var range: NSRange
        var quote: String
        var prefix: String
        var suffix: String
        var lineTime: TimeInterval?
        var text = ""
    }

    struct ScrollRequest: Equatable {
        let id: String
        let nonce: Int
    }

    /// The right column's segment; chosen again for each meeting.
    @Published var side = Side.comments
    @Published private(set) var comments: [MeetingComment] = []
    @Published private(set) var anchors: [String: CommentAnchor] = [:]
    @Published var active: String?
    @Published private(set) var draft: Draft? {
        didSet {
            if draft.map(Self.place) != oldValue.map(Self.place) { typed = draft?.text ?? "" }
        }
    }
    /// What is typed in the composer, kept here so it outlives the composer's view when the column hides or switches.
    var typed = ""
    /// Just posted, so its card animates in.
    @Published private(set) var fresh: String?
    /// The page scrolls to this text id: "summary-<block>" or "transcript-<line>".
    @Published private(set) var textScroll: ScrollRequest?
    /// The column scrolls to this card id.
    @Published private(set) var cardScroll: ScrollRequest?
    /// Comments with Claude at work on them, in any meeting.
    @Published private(set) var asking: [String: Summarizer.ClaudeCancel] = [:]
    /// Why Claude could not answer a comment, until it is asked again.
    @Published private(set) var failed: [String: String] = [:]
    /// Why this meeting's comments cannot go to Claude; nil when they can.
    @Published private(set) var askUnavailable: String?
    /// Claude's replies whose edit can still be undone.
    @Published private(set) var undoable: Set<String> = []
    /// The Resolved list at the foot of the column is open.
    @Published var showResolved = false
    /// The reply being edited in a thread.
    @Published var editingReply: String?

    private static func place(_ draft: Draft) -> [String] {
        [draft.editing ?? "", "\(draft.target)", "\(draft.unit)", NSStringFromRange(draft.range)]
    }

    /// The column scrolled to `request`; a column shown later does not jump to it again.
    func cardScrolled(_ request: ScrollRequest) {
        DispatchQueue.main.async { if self.cardScroll == request { self.cardScroll = nil } }
    }

    private(set) var meetingID: String?
    private(set) var documents: [CommentTarget: CommentDocument] = [:]
    private var nonce = 0
    let pill = CommentPillController()

    var folder: (String) -> URL? = { _ in nil }
    var onSaved: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var currentTab: () -> CommentTarget = { .summary }
    var onTab: ((CommentTarget) -> Void)?

    static let author: String = {
        let name = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? NSUserName() : name
    }()

    init() {
        pill.onComment = { [weak self] in self?.openComposer() }
    }

    /// The page's text changed or another meeting was selected.
    func show(_ page: MeetingPage?) {
        let id = page?.staged == true ? nil : page?.item.id
        let changed = id != meetingID
        if changed {
            meetingID = id
            draft = nil
            active = nil
            fresh = nil
            pill.hide()
            showResolved = false
            editingReply = nil
        }
        var documents: [CommentTarget: CommentDocument] = [:]
        if let page, id != nil {
            if let blocks = page.summary { documents[.summary] = .summary(blocks) }
            if case .lines(let lines) = page.transcript { documents[.transcript] = .transcript(lines) }
        }
        self.documents = documents
        let folder = id.flatMap(self.folder)
        comments = folder.map(CommentFile.read) ?? []
        askUnavailable = CommentRevision.unavailable(meta: page?.item.meta)
        undoable = Set(comments.flatMap { $0.replies ?? [] }.filter { CommentRevision.canUndo($0, folder: folder) }.map(\.id))
        if changed {
            // A meeting with notes and no comments opens on its notes.
            let notes = folder.flatMap { try? String(contentsOf: $0.appendingPathComponent("notes.md"), encoding: .utf8) } ?? ""
            let next: Side = !comments.contains { $0.resolvedAt == nil } && !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .notes : .comments
            if side != next { side = next }
        }
        reanchor()
    }

    private func reanchor() {
        var anchors: [String: CommentAnchor] = [:]
        for comment in comments {
            if let document = documents[comment.target], let anchor = CommentAnchoring.anchor(comment, in: document) {
                anchors[comment.id] = anchor
            }
        }
        if anchors != self.anchors { self.anchors = anchors }
        if let draft, draft.editing == nil, !hasText(draft.target, draft.unit) { self.draft = nil }
    }

    private func hasText(_ target: CommentTarget, _ unit: Int) -> Bool {
        guard let units = documents[target]?.units, units.indices.contains(unit) else { return false }
        return units[unit] != nil
    }

    // MARK: Highlights

    func highlights(_ target: CommentTarget, unit: Int) -> [TextHighlight] {
        var marks: [TextHighlight] = []
        for comment in comments where comment.target == target && comment.resolvedAt == nil {
            guard let anchor = anchors[comment.id], anchor.unit == unit else { continue }
            marks.append(TextHighlight(id: comment.id, range: anchor.range, active: side == .comments && active == comment.id, pending: false))
        }
        if let draft, draft.editing == nil, draft.target == target, draft.unit == unit {
            marks.append(TextHighlight(id: "", range: draft.range, active: false, pending: true))
        }
        return marks
    }

    // MARK: Selection

    /// Mouse-up after selecting text in one paragraph or line: the Comment button shows over it.
    func selectionEnded(in view: CommentTextView) {
        guard meetingID != nil, hasText(view.unit.target, view.unit.index), trimmedSelection(view) != nil else { return pill.hide() }
        pill.show(over: view)
    }

    func selectionCleared(in view: CommentTextView) {
        if pill.owner === view { pill.hide() }
    }

    private func trimmedSelection(_ view: CommentTextView) -> NSRange? {
        let range = CommentAnchoring.trimmed(view.selectedRange(), in: view.string as NSString)
        return range.length > 0 ? range : nil
    }

    /// The Comment button or Edit › Add Comment.
    func openComposer(from view: CommentTextView? = nil) {
        guard let view = view ?? pill.owner, let range = trimmedSelection(view),
              let document = documents[view.unit.target] else { return }
        let unit = view.unit.index
        let context = document.context(unit: unit, range: range)
        let quote = (view.string as NSString).substring(with: range)
        pill.hide()
        view.setSelectedRange(NSRange(location: range.location, length: 0))
        side = .comments
        active = nil
        draft = Draft(editing: nil, target: view.unit.target, unit: unit, range: range, quote: quote,
                      prefix: context.prefix, suffix: context.suffix,
                      lineTime: view.unit.target == .transcript ? document.times[safe: unit] : nil)
        cardScroll = request("composer")
    }

    func edit(_ id: String) {
        guard let comment = comments.first(where: { $0.id == id }) else { return }
        let anchor = anchors[id]
        draft = Draft(editing: id, target: comment.target, unit: anchor?.unit ?? -1, range: anchor?.range ?? NSRange(),
                      quote: comment.quote, prefix: comment.prefix, suffix: comment.suffix, lineTime: comment.lineTime, text: comment.text)
        active = id
    }

    func cancel() {
        draft = nil
    }

    /// Posts the composer's text: a new comment, or the edited one; `ask` sends it to Claude too.
    func post(_ raw: String, ask: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let draft, !text.isEmpty, let id = meetingID, let folder = folder(id) else { return }
        let commentID = draft.editing ?? UUID().uuidString
        do {
            comments = try CommentFile.update(folder) { list in
                if let editing = draft.editing {
                    guard let index = list.firstIndex(where: { $0.id == editing }), list[index].text != text else { return }
                    list[index].text = text
                    list[index].editedAt = Date()
                } else {
                    list.append(MeetingComment(
                        id: commentID, target: draft.target, quote: draft.quote, prefix: draft.prefix, suffix: draft.suffix,
                        lineTime: draft.lineTime, text: text, author: Self.author, createdAt: Date()))
                }
            }
            if draft.editing == nil { fresh = commentID }
            self.draft = nil
            active = commentID
            reanchor()
            onSaved?(id)
            if ask || Self.mentionsClaude(text) { self.ask(commentID) }
        } catch {
            onError?(error)
        }
    }

    /// Asks nothing; the text can be typed again.
    func delete(_ commentID: String) {
        guard let id = meetingID, let folder = folder(id) else { return }
        stopAsking(commentID)
        do {
            let replies = comments.first { $0.id == commentID }?.replies ?? []
            comments = try CommentFile.update(folder) { $0.removeAll { $0.id == commentID } }
            replies.forEach { CommentRevision.removeSaved($0.id, in: folder) }
            if active == commentID { active = nil }
            if draft?.editing == commentID { draft = nil }
            reanchor()
            onSaved?(id)
        } catch {
            onError?(error)
        }
    }

    // MARK: Claude

    /// Claude reads the comment and the text it is on, revises that text when the comment asks for it, and replies.
    func ask(_ commentID: String) {
        guard let id = meetingID, asking[commentID] == nil, askUnavailable == nil else { return }
        let cancel = Summarizer.ClaudeCancel()
        asking[commentID] = cancel
        failed[commentID] = nil
        let model = SummaryModel.current
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try CommentRevision.revise(meetingID: id, commentID: commentID, model: model, cancel: cancel) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking[commentID] = nil
                switch outcome {
                case .success:
                    self.onSaved?(id)
                    // Claude resolved the thread in view: it moves under Resolved, which opens on it.
                    if self.meetingID == id, self.active == commentID,
                       let folder = self.folder(id), CommentFile.read(folder).first(where: { $0.id == commentID })?.resolvedAt != nil {
                        self.showResolved = true
                        self.cardScroll = self.request("card-\(commentID)")
                    }
                case .failure(let error) where error is CancellationError:
                    break
                case .failure(let error):
                    self.failed[commentID] = error.localizedDescription
                }
            }
        }
    }

    /// ✓ on a card closes the comment; Reopen brings it back to its place.
    func resolve(_ commentID: String, _ resolved: Bool) {
        guard let id = meetingID, let folder = folder(id) else { return }
        do {
            comments = try CommentFile.update(folder) { list in
                guard let index = list.firstIndex(where: { $0.id == commentID }) else { return }
                list[index].resolvedAt = resolved ? Date() : nil
                list[index].resolvedBy = resolved ? Self.author : nil
            }
            if resolved, active == commentID { active = nil }
            if resolved, draft?.editing == commentID { draft = nil }
            onSaved?(id)
        } catch {
            onError?(error)
        }
    }

    func stopAsking(_ commentID: String) {
        asking[commentID]?.cancel()
        asking[commentID] = nil
    }

    /// A reply in the thread; `ask` (Send to Claude, or @claude in it) has Claude answer it.
    func reply(_ commentID: String, _ raw: String, ask: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = meetingID, let folder = folder(id) else { return }
        do {
            comments = try CommentFile.update(folder) { list in
                guard let index = list.firstIndex(where: { $0.id == commentID }) else { return }
                list[index].replies = (list[index].replies ?? [])
                    + [CommentMessage(id: UUID().uuidString, author: Self.author, text: text, createdAt: Date())]
            }
            onSaved?(id)
            if ask || Self.mentionsClaude(text) { self.ask(commentID) }
        } catch {
            onError?(error)
        }
    }

    func editReply(_ commentID: String, _ replyID: String, _ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        editingReply = nil
        guard !text.isEmpty, let id = meetingID, let folder = folder(id) else { return }
        do {
            comments = try CommentFile.update(folder) { list in
                guard let index = list.firstIndex(where: { $0.id == commentID }),
                      let reply = list[index].replies?.firstIndex(where: { $0.id == replyID }),
                      list[index].replies?[reply].text != text else { return }
                list[index].replies?[reply].text = text
                list[index].replies?[reply].editedAt = Date()
            }
            onSaved?(id)
        } catch {
            onError?(error)
        }
    }

    func deleteReply(_ commentID: String, _ replyID: String) {
        guard let id = meetingID, let folder = folder(id) else { return }
        do {
            comments = try CommentFile.update(folder) { list in
                guard let index = list.firstIndex(where: { $0.id == commentID }) else { return }
                list[index].replies?.removeAll { $0.id == replyID }
            }
            CommentRevision.removeSaved(replyID, in: folder)
            onSaved?(id)
        } catch {
            onError?(error)
        }
    }

    static func mentionsClaude(_ text: String) -> Bool {
        text.range(of: "@claude", options: .caseInsensitive) != nil
    }

    func undoRevision(_ commentID: String, _ replyID: String) {
        guard let id = meetingID else { return }
        do {
            try CommentRevision.undo(meetingID: id, commentID: commentID, messageID: replyID)
            onSaved?(id)
        } catch {
            onError?(error)
        }
    }

    // MARK: Focus

    /// A card was clicked: its highlight comes into view, on the other tab when needed.
    func focus(_ commentID: String) {
        active = commentID
        guard let comment = comments.first(where: { $0.id == commentID }), let anchor = anchors[commentID] else { return }
        if comment.target != currentTab() { onTab?(comment.target) }
        textScroll = request("\(comment.target.rawValue)-\(anchor.unit)")
    }

    /// A highlight was clicked: its card comes into view.
    func pick(_ commentID: String) {
        pill.hide()
        side = .comments
        active = commentID
        cardScroll = request("card-\(commentID)")
    }

    private func request(_ id: String) -> ScrollRequest {
        nonce += 1
        return ScrollRequest(id: id, nonce: nonce)
    }

    /// Open comments only.
    var countLabel: String {
        switch comments.filter({ $0.resolvedAt == nil }).count {
        case 0: return "Comments"
        case 1: return "1 comment"
        case let count: return "\(count) comments"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
