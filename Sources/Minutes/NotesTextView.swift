import AppKit
import Quartz
import UniformTypeIdentifiers

/// The format under the caret, for the bar's pressed and dimmed buttons and the Format menu's checkmarks.
struct NotesFormatState: Equatable {
    var block = NotesBlock.body
    var list: NotesBlock?
    var quote = false
    var link = false
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    /// In a heading: Bold does nothing there.
    var head = false
    /// In Monospaced or inline code: B I U S do nothing there.
    var code = false
}

/// notes.md as formatted text: Markdown markers are never shown, styles are. Pictures are attachments that write
/// their own `![…](frames/…)` or `![](attachments/…)` line back.
final class NotesTextView: NSTextView, NSTextStorageDelegate, QLPreviewPanelDataSource {
    var onPlay: ((TimeInterval) -> Void)?
    var onOpen: ((PictureLook) -> Void)?
    /// The bar and menus; told when the format under the caret changes.
    weak var formatter: NotesFormatter?
    var folder: URL?
    var canPlay = false
    /// The caret was put somewhere since the notes loaded, so Capture adds its picture after that line.
    var caretPlaced = false
    /// Shown in place of the first line while the notes are empty.
    var placeholder: String? { didSet { if placeholder != oldValue { needsDisplay = true } } }
    /// The format of an empty last line, which has no character to hold it.
    private(set) var emptyTail: NotesParagraph?
    private var timer: Timer?
    private var fixing = false
    private var dirty: (start: Int, tail: Int)?
    private var tickTimer: Timer?
    private weak var revealing: PictureCell?

    static let inset = NSSize(width: 12, height: 10)

    /// The text view in its scroll view, with the notes layout manager.
    static func make() -> (NSScrollView, NotesTextView) {
        let storage = NSTextStorage()
        let layout = NotesLayoutManager()
        // Long notes are laid out as far as they are seen, not all at once when a meeting opens.
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = NotesTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), textContainer: container)
        storage.delegate = view
        view.isRichText = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainerInset = inset
        view.font = NotesLook.body
        view.typingAttributes = NotesLook.attributes(NotesParagraph(), NotesInline(),
                                                     paragraphStyle: NotesLook.paragraphStyle(NotesParagraph(), previous: nil, next: nil, picture: false))
        view.setAccessibilityLabel("Notes")

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        return (scroll, view)
    }

    // MARK: Loading

    func load(_ markdown: String) {
        guard let storage = textStorage else { return }
        let lines = NotesMarkdown.parse(markdown)
        fixing = true
        storage.setAttributedString(NotesMarkdown.attributed(lines, folder: folder, canPlay: canPlay))
        fixing = false
        dirty = nil
        emptyTail = NotesMarkdown.tail(lines)
        refreshTyping()
        needsDisplay = true
    }

    var markdown: String {
        textStorage.map { NotesMarkdown.markdown($0, tail: emptyTail) } ?? ""
    }

    // MARK: Paragraphs

    private var text: NSString { (textStorage?.string ?? "") as NSString }

    /// The paragraph holding `location`, with its line break; the empty last line is `(length, 0)`.
    func paragraph(at location: Int) -> NSRange {
        let ns = text
        if location >= ns.length {
            if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A { return NSRange(location: ns.length, length: 0) }
            return ns.paragraphRange(for: NSRange(location: ns.length - 1, length: 0))
        }
        return ns.paragraphRange(for: NSRange(location: location, length: 0))
    }

    func content(_ paragraph: NSRange) -> NSRange {
        var range = paragraph
        if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
        return range
    }

    /// Every paragraph `range` touches; a selection that ends at a line start leaves that line out.
    func paragraphs(in range: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var location = range.location
        let end = range.length > 0 ? NSMaxRange(range) - 1 : range.location
        let ns = text
        let open = ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A
        repeat {
            let p = paragraph(at: location)
            out.append(p)
            if p.length == 0 || (NSMaxRange(p) >= ns.length && !open) { break }
            location = NSMaxRange(p)
        } while location <= end
        return out
    }

    var selectedParagraphs: [NSRange] { paragraphs(in: selectedRange()) }

    func format(of paragraph: NSRange) -> NotesParagraph {
        guard let storage = textStorage, paragraph.length > 0 else { return emptyTail ?? NotesParagraph() }
        return NotesParagraph(storage.attributes(at: paragraph.location, effectiveRange: nil))
    }

    func isPicture(_ paragraph: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        let range = content(paragraph)
        guard range.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if (value as? NSTextAttachment)?.attachmentCell is PictureCell { found = true; stop.pointee = true }
        }
        return found
    }

    private func block(before paragraph: NSRange) -> NotesBlock? {
        guard paragraph.location > 0 else { return nil }
        return format(of: self.paragraph(at: paragraph.location - 1)).block
    }

    private func block(after paragraph: NSRange) -> NotesBlock? {
        let end = NSMaxRange(paragraph)
        guard paragraph.length > 0, text.character(at: end - 1) == 0x0A else { return nil }
        let next = self.paragraph(at: end)
        return next.length == 0 ? emptyTail?.block : format(of: next).block
    }

    // MARK: Keeping the look

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard !fixing else { return }
        let tail = textStorage.length - NSMaxRange(editedRange)
        if let dirty {
            self.dirty = (min(dirty.start, editedRange.location), min(dirty.tail, tail))
        } else {
            dirty = (editedRange.location, tail)
        }
    }

    override func didChangeText() {
        fix()
        super.didChangeText()
        formatter?.update(from: self)
    }

    /// Each paragraph takes its format from its first character; then the look follows the format.
    private func fix() {
        guard let storage = textStorage, let dirty else { return }
        self.dirty = nil
        let start = min(dirty.start, storage.length)
        let end = max(start, storage.length - dirty.tail)
        if storage.length > 0, text.character(at: storage.length - 1) != 0x0A { emptyTail = nil }
        fixing = true
        storage.beginEditing()
        var range = NSRange(location: start, length: end - start)
        let first = paragraph(at: range.location)
        if first.location > 0 { range = NSUnionRange(range, paragraph(at: first.location - 1)) }
        let last = paragraph(at: max(range.location, NSMaxRange(range) - 1))
        if NSMaxRange(last) < storage.length { range = NSUnionRange(range, paragraph(at: NSMaxRange(last))) }
        range = NSUnionRange(range, last)
        for p in paragraphs(in: range) where p.length > 0 {
            let format = isPicture(p) ? NotesParagraph() : self.format(of: p)
            for key in NotesParagraph.keys { storage.removeAttribute(key, range: p) }
            storage.addAttributes(format.attributes, range: p)
            if format.block == .mono {
                for key in NotesParagraph.inlineKeys { storage.removeAttribute(key, range: p) }
            }
        }
        restyle(range)
        storage.endEditing()
        fixing = false
        needsDisplay = true
    }

    /// Fonts, spacing and colours from the notes attributes, for every paragraph in `range`.
    private func restyle(_ range: NSRange) {
        guard let storage = textStorage else { return }
        for p in paragraphs(in: range) where p.length > 0 {
            let format = self.format(of: p)
            let style = NotesLook.paragraphStyle(format, previous: block(before: p), next: block(after: p), picture: isPicture(p))
            storage.enumerateAttributes(in: p) { attributes, run, _ in
                for key in NotesLook.displayKeys { storage.removeAttribute(key, range: run) }
                storage.addAttributes(NotesLook.attributes(format, NotesInline(attributes), paragraphStyle: style), range: run)
            }
        }
    }

    /// What typing at the caret writes: the paragraph's format and the style of the character before it.
    func refreshTyping() {
        guard let storage = textStorage else { return }
        let caret = selectedRange().location
        let p = paragraph(at: caret)
        let format = p.length == 0 ? emptyTail ?? NotesParagraph() : self.format(of: p)
        var style = NotesInline()
        let body = content(p)
        if body.length > 0, format.block != .mono {
            let source = caret > body.location ? min(caret, NSMaxRange(body)) - 1 : body.location
            let attributes = storage.attributes(at: source, effectiveRange: nil)
            if attributes[.attachment] == nil { style = NotesInline(attributes) }
            style.raw = false
            if style.link != nil {
                var span = NSRange()
                _ = storage.attribute(.notesLink, at: source, longestEffectiveRange: &span, in: body)
                if caret == NSMaxRange(span) || caret == span.location { style.link = nil }
            }
        }
        let paragraphStyle = NotesLook.paragraphStyle(format, previous: block(before: p), next: block(after: p), picture: false)
        typingAttributes = NotesLook.attributes(format, style, paragraphStyle: paragraphStyle)
    }

    var typingStyle: NotesInline { NotesInline(typingAttributes) }

    // MARK: Changes

    /// One undo step that changes attributes only.
    private func changeAttributes(in range: NSRange, name: String, _ body: (NSTextStorage) -> Void) {
        guard let storage = textStorage else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName(name)
        breakUndoCoalescing()
    }

    /// One undo step that replaces text.
    private func replace(_ range: NSRange, with replacement: NSAttributedString, name: String, select: NSRange? = nil) {
        guard let storage = textStorage else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if let select { setSelectedRange(select) }
        undoManager?.setActionName(name)
        breakUndoCoalescing()
    }

    /// Sets the format of each paragraph `change` touches, the empty last line included.
    private func setParagraphs(_ list: [NSRange], name: String, clearInline: Bool = false,
                               _ change: (inout NotesParagraph) -> Void) {
        let held = list.filter { $0.length > 0 && !isPicture($0) }
        if let tail = list.first(where: { $0.length == 0 }) {
            var format = emptyTail ?? NotesParagraph()
            change(&format)
            emptyTail = format
            _ = tail
        }
        if let first = held.first, let last = held.last {
            let union = NSUnionRange(first, last)
            let keep = selectedRanges
            changeAttributes(in: union, name: name) { storage in
                for p in held {
                    var format = self.format(of: p)
                    change(&format)
                    for key in NotesParagraph.keys { storage.removeAttribute(key, range: p) }
                    storage.addAttributes(format.attributes, range: p)
                    if clearInline || format.block == .mono {
                        for key in NotesParagraph.inlineKeys { storage.removeAttribute(key, range: p) }
                    }
                }
            }
            selectedRanges = keep
        }
        refreshTyping()
        needsDisplay = true
        formatter?.update(from: self)
    }

    // MARK: Format

    var formatState: NotesFormatState {
        guard let storage = textStorage else { return NotesFormatState() }
        let selection = selectedRange()
        let p = paragraph(at: selection.location)
        let format = self.format(of: p)
        var state = NotesFormatState()
        state.block = format.block.isList || format.block == .quote ? .body : format.block
        state.list = format.block.isList ? format.block : nil
        state.quote = format.block == .quote
        state.head = format.block.isHeading
        let style: NotesInline
        if selection.length == 0 {
            style = typingStyle
        } else {
            var all = NotesInline(bold: true, italic: true, underline: true, strike: true, code: true, link: "")
            var any = false
            for range in textRanges(in: selection) {
                storage.enumerateAttributes(in: range) { attributes, _, _ in
                    let s = NotesInline(attributes)
                    any = true
                    all.bold = all.bold && s.bold
                    all.italic = all.italic && s.italic
                    all.underline = all.underline && s.underline
                    all.strike = all.strike && s.strike
                    all.code = all.code && s.code
                    if s.link == nil { all.link = nil }
                }
            }
            style = any ? all : NotesInline()
        }
        state.code = format.block == .mono || style.code
        state.link = style.link != nil || linkSpan(at: selection.location) != nil
        state.bold = style.bold && !state.head && !state.code
        state.italic = style.italic && !state.code
        state.underline = style.underline && !state.code
        state.strike = style.strike && !state.code
        return state
    }

    /// The parts of `range` that hold styled text: no line breaks, pictures or Monospaced lines.
    private func textRanges(in range: NSRange) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        var out: [NSRange] = []
        for p in paragraphs(in: range) where p.length > 0 && format(of: p).block != .mono {
            let part = NSIntersectionRange(content(p), range)
            guard part.length > 0 else { continue }
            storage.enumerateAttribute(.attachment, in: part) { value, run, _ in
                if value == nil { out.append(run) }
            }
        }
        return out
    }

    @objc func formatTitle(_ sender: Any?) { setBlock(.title) }
    @objc func formatHeading(_ sender: Any?) { setBlock(.heading) }
    @objc func formatSubheading(_ sender: Any?) { setBlock(.subheading) }
    @objc func formatBody(_ sender: Any?) { setBlock(.body) }
    @objc func formatMonospaced(_ sender: Any?) { setBlock(.mono) }
    @objc func formatBold(_ sender: Any?) { toggle(.notesBold) }
    @objc func formatItalic(_ sender: Any?) { toggle(.notesItalic) }
    @objc func formatUnderline(_ sender: Any?) { toggle(.notesUnderline) }
    @objc func formatStrikethrough(_ sender: Any?) { toggle(.notesStrike) }
    @objc func formatBulletedList(_ sender: Any?) { setList(.bullet) }
    @objc func formatDashedList(_ sender: Any?) { setList(.dash) }
    @objc func formatNumberedList(_ sender: Any?) { setList(.number) }
    @objc func formatChecklist(_ sender: Any?) { setList(.check) }
    @objc func formatMarkChecked(_ sender: Any?) { toggleChecked() }
    @objc func formatBlockQuote(_ sender: Any?) { toggleQuote() }
    @objc func formatLink(_ sender: Any?) { openLink() }

    private static let names: [NotesBlock: String] = [
        .title: "Title", .heading: "Heading", .subheading: "Subheading", .body: "Body", .mono: "Monospaced",
        .bullet: "Bulleted List", .dash: "Dashed List", .number: "Numbered List", .check: "Checklist", .quote: "Block Quote",
    ]

    func setBlock(_ block: NotesBlock) {
        if block == .mono, codeSpanCase() {
            toggle(.notesCode)
            return
        }
        setParagraphs(selectedParagraphs, name: Self.names[block] ?? "Format") { format in
            let fence = format.block == .mono ? format.fence : nil
            format = NotesParagraph(block: block, fence: block == .mono ? fence : nil)
        }
    }

    /// Monospaced on part of one line, or with the caret in inline code, is inline code.
    private func codeSpanCase() -> Bool {
        let selection = selectedRange()
        if selection.length == 0 { return typingStyle.code }
        let list = selectedParagraphs
        guard list.count == 1, format(of: list[0]).block != .mono else { return false }
        let line = text.substring(with: content(list[0])).trimmingCharacters(in: .whitespaces)
        let chosen = text.substring(with: selection).trimmingCharacters(in: .whitespaces)
        return chosen != line
    }

    func setList(_ kind: NotesBlock) {
        let list = selectedParagraphs.filter { !isPicture($0) }
        guard !list.isEmpty else { return }
        let all = list.allSatisfy { format(of: $0).block == kind }
        setParagraphs(list, name: Self.names[kind] ?? "List") { format in
            if all {
                format = NotesParagraph()
            } else {
                let level = format.block.isList ? format.level : 0
                let checked = format.block == .check && format.checked
                format = NotesParagraph(block: kind, level: level, checked: kind == .check && checked)
            }
        }
    }

    func toggleQuote() {
        let list = selectedParagraphs.filter { !isPicture($0) }
        guard let first = list.first else { return }
        let off = format(of: first).block == .quote
        setParagraphs(list, name: "Block Quote") { format in
            format = NotesParagraph(block: off ? (format.block == .quote ? .body : format.block) : .quote)
        }
    }

    func toggleChecked() {
        let items = selectedParagraphs.filter { format(of: $0).block == .check }
        guard !items.isEmpty else { return }
        let on = items.contains { !format(of: $0).checked }
        setParagraphs(items, name: on ? "Mark as Checked" : "Mark as Unchecked") { $0.checked = on }
        if let first = items.first { animateTick(first.location, on: on) }
    }

    private func toggle(_ key: NSAttributedString.Key) {
        let state = formatState
        if state.code && key != .notesCode { return }
        if key == .notesBold && state.head { return }
        let selection = selectedRange()
        let names: [NSAttributedString.Key: String] = [.notesBold: "Bold", .notesItalic: "Italic", .notesUnderline: "Underline",
                                                       .notesStrike: "Strikethrough", .notesCode: "Code"]
        if selection.length == 0 {
            if key == .notesCode, let span = span(of: .notesCode, at: selection.location) {
                changeAttributes(in: span, name: "Code") { $0.removeAttribute(.notesCode, range: span) }
                refreshTyping()
            } else {
                var attributes = typingAttributes
                if attributes[key] != nil { attributes[key] = nil } else { attributes[key] = true }
                let format = NotesParagraph(attributes)
                let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle.default
                typingAttributes = NotesLook.attributes(format, NotesInline(attributes), paragraphStyle: paragraphStyle)
            }
            formatter?.update(from: self)
            return
        }
        let ranges = textRanges(in: selection)
        guard let storage = textStorage, let first = ranges.first, let last = ranges.last else { return }
        var all = true
        for range in ranges {
            storage.enumerateAttribute(key, in: range) { value, _, stop in
                if value == nil { all = false; stop.pointee = true }
            }
        }
        changeAttributes(in: NSUnionRange(first, last), name: names[key] ?? "Format") { storage in
            for range in ranges {
                if all { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: true, range: range) }
            }
        }
        setSelectedRange(selection)
        formatter?.update(from: self)
    }

    private func span(of key: NSAttributedString.Key, at location: Int) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let body = content(paragraph(at: location))
        for index in [location - 1, location] where NSLocationInRange(index, body) {
            var span = NSRange()
            if storage.attribute(key, at: index, longestEffectiveRange: &span, in: body) != nil { return span }
        }
        return nil
    }

    func linkSpan(at location: Int) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let body = content(paragraph(at: location))
        let selection = selectedRange()
        let index = selection.length > 0 ? selection.location : location
        for i in [index, index - 1] where NSLocationInRange(i, body) {
            var span = NSRange()
            if storage.attribute(.notesLink, at: i, longestEffectiveRange: &span, in: body) != nil {
                if selection.length == 0, i == index - 1, NSMaxRange(span) == location { continue }
                return span
            }
        }
        return nil
    }

    /// Tab and Shift-Tab: an item moves with the items under it, at most one level below the item above.
    func indent(_ delta: Int) {
        let list = selectedParagraphs.filter { format(of: $0).block.isList }
        guard let first = list.first else { return }
        let firstLevel = format(of: first).level
        if delta > 0 {
            guard first.location > 0 else { return }
            let above = format(of: paragraph(at: first.location - 1))
            guard above.block.isList, above.level >= firstLevel else { return }
        } else if list.allSatisfy({ format(of: $0).level == 0 }) {
            return
        }
        var moved: [NSRange] = []
        var location = first.location
        let selectionEnd = NSMaxRange(list.last!)
        var floor = Int.max
        while location < text.length {
            let p = paragraph(at: location)
            let format = self.format(of: p)
            guard format.block.isList else { break }
            if p.location < selectionEnd {
                moved.append(p)
                floor = min(floor, format.level)
            } else if format.level > floor && format.level > self.format(of: list.last!).level {
                moved.append(p)
            } else if format.level > floor, let last = moved.last, NSMaxRange(last) == p.location, self.format(of: last).level < format.level {
                moved.append(p)
            } else {
                break
            }
            location = NSMaxRange(p)
        }
        setParagraphs(moved, name: delta > 0 ? "Indent" : "Outdent") { format in
            format.level = max(0, format.level + delta)
        }
    }

    // MARK: Links

    private var linkTarget: NSRange?

    func openLink() {
        let selection = selectedRange()
        let span = linkSpan(at: selection.location)
        linkTarget = span ?? selection
        let url = span.flatMap { textStorage?.attribute(.notesLink, at: $0.location, effectiveRange: nil) as? String }
        formatter?.showLink(url: url ?? "https://", existing: span != nil)
    }

    func applyLink(_ input: String) {
        defer { linkTarget = nil }
        var url = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, url != "https://", let target = linkTarget else { return }
        if url.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil { url = "https://" + url }
        if target.length > 0 {
            let ranges = textRanges(in: target)
            guard let first = ranges.first, let last = ranges.last else { return }
            changeAttributes(in: NSUnionRange(first, last), name: "Link") { storage in
                for range in ranges { storage.addAttribute(.notesLink, value: url, range: range) }
            }
            setSelectedRange(target)
        } else {
            var attributes = typingAttributes
            attributes[.notesLink] = url
            let format = NotesParagraph(attributes)
            let style = attributes[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle.default
            let piece = NSAttributedString(string: url, attributes: NotesLook.attributes(format, NotesInline(attributes), paragraphStyle: style))
            replace(target, with: piece, name: "Link", select: NSRange(location: target.location + piece.length, length: 0))
        }
        formatter?.update(from: self)
    }

    func removeLink() {
        defer { linkTarget = nil }
        guard let target = linkTarget, let span = linkSpan(at: target.location) ?? (target.length > 0 ? target : nil) else { return }
        changeAttributes(in: span, name: "Remove Link") { $0.removeAttribute(.notesLink, range: span) }
        setSelectedRange(target)
        formatter?.update(from: self)
    }

    // MARK: Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let selection = selectedRange()
        if typed == " ", selection.length == 0, replacementRange.location == NSNotFound || replacementRange == selection, autoformat() { return }
        // Text never shares a line with a picture.
        if selection.length == 0, replacementRange.location == NSNotFound, !typed.isEmpty, let storage = textStorage {
            let caret = selection.location
            if caret > 0, storage.attribute(.attachment, at: caret - 1, effectiveRange: nil) != nil,
               isPicture(paragraph(at: caret - 1)) {
                setTypingBody()
                super.insertText("\n" + typed, replacementRange: replacementRange)
                return
            }
            if caret < storage.length, storage.attribute(.attachment, at: caret, effectiveRange: nil) != nil,
               isPicture(paragraph(at: caret)) {
                setTypingBody()
                super.insertText(typed + "\n", replacementRange: replacementRange)
                setSelectedRange(NSRange(location: caret + (typed as NSString).length, length: 0))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    private func setTypingBody() {
        typingAttributes = NotesLook.attributes(NotesParagraph(), NotesInline(),
                                                paragraphStyle: NotesLook.paragraphStyle(NotesParagraph(), previous: nil, next: nil, picture: false))
    }

    /// Line-start shortcuts on Space: `# ` `## ` `### ` `- ` `* ` `1. ` `> ` `[] ` and ```` ``` ````.
    private func autoformat() -> Bool {
        guard let storage = textStorage else { return false }
        let caret = selectedRange().location
        let p = paragraph(at: caret)
        let format = self.format(of: p)
        guard format.block != .mono, p.length > 0 || caret == text.length else { return false }
        let start = p.length > 0 ? p.location : caret
        let typed = text.substring(with: NSRange(location: start, length: caret - start))
        let actions: [String: NotesParagraph]
        if format.block.isList {
            let level = format.level
            actions = ["[]": NotesParagraph(block: .check, level: level), "[ ]": NotesParagraph(block: .check, level: level),
                       "[x]": NotesParagraph(block: .check, level: level, checked: true)]
        } else {
            actions = ["#": NotesParagraph(block: .title), "##": NotesParagraph(block: .heading), "###": NotesParagraph(block: .subheading),
                       "-": NotesParagraph(block: .dash), "*": NotesParagraph(block: .bullet), "1.": NotesParagraph(block: .number),
                       ">": NotesParagraph(block: .quote), "[]": NotesParagraph(block: .check), "[ ]": NotesParagraph(block: .check),
                       "```": NotesParagraph(block: .mono)]
        }
        guard let target = actions[typed] else { return false }
        let rest = NSRange(location: caret, length: NSMaxRange(p) - caret)
        let kept = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: rest.length > 0 ? rest : NSRange(location: caret, length: 0)))
        if kept.length > 0 {
            for key in NotesParagraph.keys { kept.removeAttribute(key, range: NSRange(location: 0, length: kept.length)) }
            kept.addAttributes(target.attributes, range: NSRange(location: 0, length: kept.length))
            if target.block == .mono {
                for key in NotesParagraph.inlineKeys { kept.removeAttribute(key, range: NSRange(location: 0, length: kept.length)) }
            }
        }
        let whole = NSRange(location: start, length: NSMaxRange(p.length > 0 ? p : rest) - start)
        if kept.length == 0 { emptyTail = target }
        replace(whole, with: kept, name: Self.names[target.block] ?? "Format", select: NSRange(location: start, length: 0))
        refreshTyping()
        formatter?.update(from: self)
        return true
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let p = paragraph(at: selection.location)
        let format = self.format(of: p)
        let body = content(p)
        if selection.length == 0, format.block.isList || format.block == .quote, body.length == 0 {
            // Return on an empty item leaves the list.
            setParagraphs([p], name: "Body") { $0 = NotesParagraph() }
            return
        }
        let atEnd = selection.location >= NSMaxRange(body)
        super.insertNewline(sender)
        let next = paragraph(at: selectedRange().location)
        var follow = format
        if format.block.isHeading && atEnd { follow = NotesParagraph() }
        follow.checked = false
        if next.length == 0 {
            emptyTail = follow
        } else if follow != self.format(of: next), let storage = textStorage {
            fixing = true
            storage.beginEditing()
            for key in NotesParagraph.keys { storage.removeAttribute(key, range: next) }
            storage.addAttributes(follow.attributes, range: next)
            restyle(NSUnionRange(p, next))
            storage.endEditing()
            fixing = false
        }
        refreshTyping()
        needsDisplay = true
        formatter?.update(from: self)
    }

    override func insertTab(_ sender: Any?) {
        let p = paragraph(at: selectedRange().location)
        if format(of: p).block.isList { return indent(1) }
        if selectedRange().location > p.location || selectedRange().length > 0 { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if format(of: paragraph(at: selectedRange().location)).block.isList { indent(-1) }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, let storage = textStorage else { return super.deleteBackward(sender) }
        let caret = selection.location
        let p = paragraph(at: caret)
        let format = self.format(of: p)
        if caret == p.location || p.length == 0 {
            if format.block.isList {
                if format.level > 0 { return indent(-1) }
                return setParagraphs([p], name: "Body") { $0 = NotesParagraph() }
            }
            if format.block == .quote { return setParagraphs([p], name: "Body") { $0 = NotesParagraph() } }
            // One Backspace takes a picture away, line and all.
            if caret > 0, content(p).length > 0 {
                let above = paragraph(at: caret - 1)
                if isPicture(above) { return deletePicture(above) }
            }
        }
        if caret > 0, storage.attribute(.attachment, at: caret - 1, effectiveRange: nil) != nil {
            let holder = paragraph(at: caret - 1)
            if isPicture(holder) { return deletePicture(holder) }
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, let storage = textStorage, selection.location < storage.length else { return super.deleteForward(sender) }
        let caret = selection.location
        if storage.attribute(.attachment, at: caret, effectiveRange: nil) != nil, isPicture(paragraph(at: caret)) {
            return deletePicture(paragraph(at: caret))
        }
        let p = paragraph(at: caret)
        if caret == NSMaxRange(content(p)), NSMaxRange(p) < storage.length, content(p).length > 0 {
            let below = paragraph(at: NSMaxRange(p))
            if isPicture(below) { return deletePicture(below) }
        }
        super.deleteForward(sender)
    }

    private func deletePicture(_ p: NSRange) {
        var range = p
        let caret: Int
        if text.character(at: NSMaxRange(p) - 1) != 0x0A, p.location > 0 {
            range = NSRange(location: p.location - 1, length: p.length + 1)
            caret = p.location - 1
        } else {
            caret = p.location
        }
        replace(range, with: NSAttributedString(), name: "Delete Picture", select: NSRange(location: caret, length: 0))
    }

    // MARK: Pictures

    /// A Capture picture as its own line after the caret's line, or at the end before the caret was placed.
    func insertPicture(_ source: String) -> Bool {
        insertPictures([source], atEnd: !caretPlaced, name: "Capture")
    }

    /// Picture lines as blocks after the caret's line (an empty line takes the first itself), in one undo step.
    @discardableResult
    func insertPictures(_ sources: [String], atEnd: Bool = false, name: String) -> Bool {
        guard isEditable, let storage = textStorage, !sources.isEmpty,
              sources.allSatisfy({ NotesAttachments.pictureLine($0) != nil }) else { return false }
        let line = atEnd ? paragraph(at: storage.length) : paragraph(at: selectedRange().location)
        let body = NotesLook.attributes(NotesParagraph(), NotesInline(),
                                        paragraphStyle: NotesLook.paragraphStyle(NotesParagraph(), previous: nil, next: nil, picture: true))
        let empty = content(line).length == 0 && !isPicture(line)
        let at = empty ? line.location : NSMaxRange(content(line))
        let breaks = NSMaxRange(line) > NSMaxRange(content(line))
        let needsLine = !breaks || isPicture(paragraph(at: NSMaxRange(line)))
        let piece = NSMutableAttributedString()
        for (index, source) in sources.enumerated() {
            if index > 0 || !empty { piece.append(NSAttributedString(string: "\n", attributes: body)) }
            piece.append(NotesMarkdown.attributed([NotesLine(picture: source)], folder: folder, canPlay: canPlay))
        }
        if needsLine { piece.append(NSAttributedString(string: "\n", attributes: body)) }
        let last = at + piece.length - (needsLine ? 2 : 1)
        replace(NSRange(location: at, length: 0), with: piece, name: name,
                select: NSRange(location: min(last + 2, storage.length + piece.length), length: 0))
        caretPlaced = true
        if let layout = layoutManager, let container = textContainer {
            layout.ensureLayout(for: container)
            sizeToFit()
        }
        if let source = sources.last { reveal(source) }
        scrollRangeToVisible(NSRange(location: last, length: 1))
        return true
    }

    /// Copies pictures into attachments/ and puts them in as blocks.
    @discardableResult
    func insertPictureFiles(_ files: [URL]) -> Bool {
        guard let folder else { return false }
        var sources: [String] = []
        for file in files {
            do {
                sources.append(NotesAttachments.line(for: (try NotesAttachments.store(file: file, in: folder) as NSString).lastPathComponent))
            } catch {
                onError?(error)
            }
        }
        return insertPictures(sources, name: sources.count > 1 ? "Insert Pictures" : "Insert Picture")
    }

    var onError: ((Error) -> Void)?

    /// Image files from Finder or another app, or picture data (a screenshot, a copied image). False when there is none.
    func insertImages(from pboard: NSPasteboard, preferText: Bool) -> Bool {
        guard isEditable, let folder else { return false }
        let files = (pboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL]) ?? []
        if !files.isEmpty { return insertPictureFiles(files) }
        if preferText, pboard.string(forType: .string)?.isEmpty == false { return false }
        guard let type = NotesAttachments.imageTypes.first(where: { pboard.data(forType: $0) != nil }),
              let data = pboard.data(forType: type) else { return false }
        do {
            let path = try NotesAttachments.store(data, name: "Pasted picture", in: folder)
            return insertPictures([NotesAttachments.line(for: (path as NSString).lastPathComponent)], name: "Paste Picture")
        } catch {
            onError?(error)
            return false
        }
    }

    @objc func formatInsertPicture(_ sender: Any?) {
        guard isEditable, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.window?.makeFirstResponder(self)
            self.insertPictureFiles(panel.urls)
        }
    }

    // MARK: Quick Look

    /// Stands in for the Quick Look panel in tests.
    var onQuickLook: ((URL) -> Void)?
    private var lookURL: URL?

    func quickLook(_ url: URL) {
        if let onQuickLook { return onQuickLook(url) }
        lookURL = url
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { lookURL != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        lookURL = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { lookURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { lookURL as NSURL? }

    // MARK: Paste and copy

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.fileURL] + NotesAttachments.imageTypes + [.string] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { readablePasteboardTypes }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func paste(_ sender: Any?) { pastePlain(NSPasteboard.general) }
    override func pasteAsPlainText(_ sender: Any?) { pastePlain(NSPasteboard.general) }
    override func pasteAsRichText(_ sender: Any?) { pastePlain(NSPasteboard.general) }

    // Drops land here, with the caret already moved to the drop point.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if insertImages(from: pboard, preferText: false) { return true }
        guard let string = pboard.string(forType: .string), !string.isEmpty else { return false }
        insertPlain(string, copied: NotesAttachments.copied(from: pboard))
        return true
    }

    /// Pasted text arrives as plain text in the line's format; whole picture lines become pictures.
    func pastePlain(_ pboard: NSPasteboard) {
        // Text wins over a picture of it (a copied table cell carries both); a copied file or screenshot does not.
        if insertImages(from: pboard, preferText: true) { return }
        guard let string = pboard.string(forType: .string), !string.isEmpty else { return }
        insertPlain(string, copied: NotesAttachments.copied(from: pboard))
    }

    /// `copied`: where the pictures copied out of Notes are, by their line.
    func insertPlain(_ string: String, copied: [String: String] = [:]) {
        let selection = selectedRange()
        let normal = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        var attributes = typingAttributes
        for key in NotesParagraph.inlineKeys { attributes[key] = nil }
        let format = NotesParagraph(attributes)
        let style = attributes[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle.default
        let plain = NotesLook.attributes(format, NotesInline(), paragraphStyle: style)
        let piece = NSMutableAttributedString()
        let lines = normal.components(separatedBy: "\n")
        let p = paragraph(at: selection.location)
        for (index, line) in lines.enumerated() {
            if index > 0 { piece.append(NSAttributedString(string: "\n", attributes: plain)) }
            if folder != nil, NotesAttachments.pictureLine(line) != nil {
                if index == 0, selection.location > p.location { piece.append(NSAttributedString(string: "\n", attributes: plain)) }
                piece.append(NotesMarkdown.attributed([NotesLine(picture: local(line, copied: copied))], folder: folder, canPlay: canPlay))
                if index == lines.count - 1, NSMaxRange(selection) < NSMaxRange(content(p)) {
                    piece.append(NSAttributedString(string: "\n", attributes: plain))
                }
            } else {
                piece.append(NSAttributedString(string: line, attributes: plain))
            }
        }
        replace(selection, with: piece, name: "Paste", select: NSRange(location: selection.location + piece.length, length: 0))
    }

    /// A picture line pasted from another meeting, or whose file is not here, gets its own copy in attachments/.
    private func local(_ line: String, copied: [String: String]) -> String {
        guard let folder, let path = NotesAttachments.pictureLine(line)?.path, let origin = copied[line] else { return line }
        let source = URL(fileURLWithPath: origin)
        let here = folder.appendingPathComponent(path)
        let fm = FileManager.default
        guard source.standardizedFileURL != here.standardizedFileURL || !fm.fileExists(atPath: here.path),
              fm.fileExists(atPath: source.path) else { return line }
        do {
            return NotesAttachments.line(for: (try NotesAttachments.store(file: source, in: folder) as NSString).lastPathComponent)
        } catch {
            onError?(error)
            return line
        }
    }

    // Copying gives the text as shown, and a picture as its Markdown line plus where its file is.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return super.writeSelection(to: pboard, type: type) }
        var files: [String: String] = [:]
        let text = selectedRanges.map { value -> String in
            var out = ""
            storage.enumerateAttribute(.attachment, in: value.rangeValue) { attachment, range, _ in
                if let cell = (attachment as? NSTextAttachment)?.attachmentCell as? PictureCell {
                    out += cell.source
                    files[cell.source] = cell.look.url.path
                } else {
                    out += (storage.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                }
            }
            return out
        }.joined(separator: "\n")
        pboard.clearContents()
        if !files.isEmpty { pboard.setPropertyList(files, forType: NotesAttachments.pasteboardType) }
        return pboard.setString(text, forType: .string)
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let action = Self.shortcut(event) else { return super.performKeyEquivalent(with: event) }
        perform(action, with: nil)
        return true
    }

    /// The Format menu's shortcuts, matched here too so they work with any keyboard layout's shifted digits.
    static func shortcut(_ event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "b": return #selector(formatBold(_:))
            case "i": return #selector(formatItalic(_:))
            case "u": return #selector(formatUnderline(_:))
            case "k": return #selector(formatLink(_:))
            case "'": return #selector(formatBlockQuote(_:))
            default: return event.keyCode == 39 ? #selector(formatBlockQuote(_:)) : nil
            }
        }
        guard flags == [.command, .shift] else { return nil }
        switch event.keyCode {
        case 26: return #selector(formatBulletedList(_:))
        case 28: return #selector(formatDashedList(_:))
        case 25: return #selector(formatNumberedList(_:))
        default: break
        }
        switch key {
        case "x": return #selector(formatStrikethrough(_:))
        case "t": return #selector(formatTitle(_:))
        case "h": return #selector(formatHeading(_:))
        case "j": return #selector(formatSubheading(_:))
        case "b": return #selector(formatBody(_:))
        case "m": return #selector(formatMonospaced(_:))
        case "l": return #selector(formatChecklist(_:))
        case "u": return #selector(formatMarkChecked(_:))
        case "i": return #selector(formatInsertPicture(_:))
        default: return nil
        }
    }

    // NSTextView would open the word-completion list; Esc only closes things here.
    override func cancelOperation(_ sender: Any?) {
        formatter?.closeAll()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return super.validateMenuItem(item) }
        let state = formatState
        let blocks: [Selector: NotesBlock] = [
            #selector(formatTitle(_:)): .title, #selector(formatHeading(_:)): .heading, #selector(formatSubheading(_:)): .subheading,
            #selector(formatBody(_:)): .body, #selector(formatMonospaced(_:)): .mono,
        ]
        let lists: [Selector: NotesBlock] = [
            #selector(formatBulletedList(_:)): .bullet, #selector(formatDashedList(_:)): .dash,
            #selector(formatNumberedList(_:)): .number, #selector(formatChecklist(_:)): .check,
        ]
        if let block = blocks[action] {
            item.state = state.list == nil && !state.quote && state.block == block ? .on : .off
            return isEditable
        }
        if let list = lists[action] {
            item.state = state.list == list ? .on : .off
            return isEditable
        }
        switch action {
        case #selector(formatBold(_:)):
            item.state = state.bold ? .on : .off
            return isEditable && !state.head && !state.code
        case #selector(formatItalic(_:)):
            item.state = state.italic ? .on : .off
            return isEditable && !state.code
        case #selector(formatUnderline(_:)):
            item.state = state.underline ? .on : .off
            return isEditable && !state.code
        case #selector(formatStrikethrough(_:)):
            item.state = state.strike ? .on : .off
            return isEditable && !state.code
        case #selector(formatBlockQuote(_:)):
            item.state = state.quote ? .on : .off
            return isEditable
        case #selector(formatMarkChecked(_:)):
            return isEditable && selectedParagraphs.contains { format(of: $0).block == .check }
        case #selector(formatLink(_:)), #selector(formatInsertPicture(_:)):
            return isEditable && (action != #selector(formatInsertPicture(_:)) || folder != nil)
        default:
            return super.validateMenuItem(item)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let placeholder, textStorage?.length == 0 else { return }
        (placeholder as NSString).draw(at: textContainerOrigin,
                                       withAttributes: [.font: NotesLook.body, .foregroundColor: NSColor.placeholderTextColor])
    }

    // MARK: Mouse

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { formatter?.setFocused(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { formatter?.setFocused(false) }
        return resigned
    }

    private func picture(at point: NSPoint) -> PictureCell? {
        guard let storage = textStorage else { return nil }
        var found: PictureCell?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? PictureCell, cell.box.contains(point) {
                found = cell
                stop.pointee = true
            }
        }
        return found
    }

    /// The checklist paragraph whose box (the first 20 pt of the item) is under `point`.
    func checkbox(at point: NSPoint) -> NSRange? {
        guard let layout = layoutManager as? NotesLayoutManager, let container = textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let p = paragraph(at: layout.characterIndexForGlyph(at: glyph))
        guard p.length > 0, format(of: p).block == .check, let zone = layout.checkZone(for: p) else { return nil }
        return zone.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).contains(point) ? p : nil
    }

    override func mouseDown(with event: NSEvent) {
        formatter?.closeAll()
        let point = convert(event.locationInWindow, from: nil)
        if let cell = picture(at: point) {
            if cell.look.canPlay, let time = cell.look.time, cell.chip.contains(point) {
                onPlay?(time)
            } else if cell.isAttachment {
                quickLook(cell.look.url)
            } else {
                onOpen?(cell.look)
            }
            return
        }
        if isEditable, let item = checkbox(at: point) {
            // Ticks without moving the caret.
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
            let keep = selectedRanges
            let on = !format(of: item).checked
            setParagraphs([item], name: on ? "Mark as Checked" : "Mark as Unchecked") { $0.checked = on }
            selectedRanges = keep
            animateTick(item.location, on: on)
            return
        }
        if event.modifierFlags.contains(.command), let storage = textStorage {
            let index = characterIndexForInsertion(at: point)
            if index < storage.length, let url = (storage.attribute(.notesLink, at: index, effectiveRange: nil) as? String).flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        super.mouseDown(with: event)
        caretPlaced = true
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        caretPlaced = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard picture(at: point) != nil || (isEditable && checkbox(at: point) != nil) else { return super.mouseMoved(with: event) }
        NSCursor.pointingHand.set()
    }

    // MARK: Motion

    private func animateTick(_ location: Int, on: Bool) {
        guard let layout = layoutManager as? NotesLayoutManager, !Motion.reduceMotion else { return }
        let start = Date()
        layout.tick = (location, 0)
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self, weak layout] timer in
            guard let self, let layout else { return timer.invalidate() }
            let t = min(1, Date().timeIntervalSince(start) / (0.12 * Motion.timeScale))
            layout.tick = t >= 1 ? nil : (location, t)
            self.needsDisplay = true
            if t >= 1 { timer.invalidate() }
        }
    }

    /// A captured picture fades in, sliding 6 pt down into place.
    func reveal(_ source: String) {
        guard let storage = textStorage else { return }
        var cells: [PictureCell] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? PictureCell, cell.source == source { cells.append(cell) }
        }
        guard let cell = cells.last else { return }
        // One still coming in finishes at once rather than staying hidden.
        if let revealing, revealing !== cell { revealing.progress = 1 }
        revealing = cell
        let still = Motion.reduceMotion
        let start = Date()
        let duration = Motion.appearDuration
        cell.progress = 0
        cell.slides = !still
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self, weak cell] timer in
            guard let self, let cell else { return timer.invalidate() }
            let t = min(1, Date().timeIntervalSince(start) / duration)
            // Ease out.
            cell.progress = 1 - (1 - t) * (1 - t)
            self.setNeedsDisplay(cell.frame.insetBy(dx: -2, dy: -8))
            if t >= 1 { timer.invalidate() }
        }
    }
}

// MARK: Drawing

/// Draws what Markdown markers stand for: bullets, dashes, numbers, check circles, quote bars and code blocks.
final class NotesLayoutManager: NSLayoutManager {
    /// A check circle filling or emptying, by its paragraph's first character and progress 0…1.
    var tick: (location: Int, progress: Double)?

    private var view: NotesTextView? { firstTextView as? NotesTextView }

    private func baseline(_ glyph: Int) -> CGFloat {
        lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + location(forGlyphAt: glyph).y
    }

    /// The first line's baseline and the font of a paragraph's first character.
    private func firstLine(_ p: NSRange) -> (baseline: CGFloat, font: NSFont)? {
        guard let storage = textStorage, p.length > 0 else { return nil }
        let glyph = glyphIndexForCharacter(at: p.location)
        guard glyph < numberOfGlyphs else { return nil }
        let font = storage.attribute(.font, at: p.location, effectiveRange: nil) as? NSFont ?? NotesLook.body
        return (baseline(glyph), font)
    }

    private func lastBaseline(_ p: NSRange) -> CGFloat? {
        guard p.length > 0 else { return nil }
        let glyph = glyphIndexForCharacter(at: NSMaxRange(p) - 1)
        guard glyph < numberOfGlyphs else { return nil }
        // A line break's glyph sits on the line it ends.
        return baseline(glyph)
    }

    /// Where a click ticks a checklist item: the 20 pt before its text, on its first line.
    func checkZone(for p: NSRange) -> NSRect? {
        guard let view, let line = firstLine(p) else { return nil }
        let indent = NotesLook.indent(view.format(of: p))
        let rect = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: p.location), effectiveRange: nil)
        return NSRect(x: indent - 23, y: rect.minY, width: 20, height: line.baseline - rect.minY + 6)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let view, let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        drawCodeSpans(in: chars, container: container, origin: origin)
        let ns = storage.string as NSString
        let width = container.size.width
        var location = ns.length == 0 ? 0 : ns.paragraphRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        // Code blocks and quotes are drawn whole, so start at the top of the one on screen.
        while location > 0 {
            let above = view.paragraph(at: location - 1)
            let block = view.format(of: above).block
            guard block == .mono || block == .quote else { break }
            location = above.location
        }
        var items: [(block: NotesBlock, level: Int)] = []
        var listStart = location
        while listStart > 0 {
            let above = view.paragraph(at: listStart - 1)
            guard view.format(of: above).block.isList else { break }
            listStart = above.location
        }
        // Numbers count from the top of the list.
        var counting = listStart
        while counting < location {
            let p = view.paragraph(at: counting)
            let format = view.format(of: p)
            items.append((format.block, format.level))
            counting = NSMaxRange(p)
        }
        let end = NSMaxRange(chars)
        while location < ns.length && location <= end {
            let p = view.paragraph(at: location)
            let format = view.format(of: p)
            items.append((format.block, format.level))
            if format.block == .mono || format.block == .quote {
                var last = p
                while NSMaxRange(last) < ns.length {
                    let next = view.paragraph(at: NSMaxRange(last))
                    guard next.length > 0, view.format(of: next).block == format.block else { break }
                    last = next
                    items.append((format.block, 0))
                }
                drawRun(format.block, from: p, to: last, width: width, origin: origin)
                location = NSMaxRange(last)
                continue
            }
            if format.block.isList, let line = firstLine(p) {
                let number = NotesMarkdown.numbers(items).last ?? nil
                drawMarker(format, number: number, baseline: line.baseline, font: line.font, location: p.location, origin: origin)
            }
            location = NSMaxRange(p)
        }
        // The empty last line keeps a marker while it is still an item.
        if let tail = view.emptyTail, tail.block.isList, extraLineFragmentTextContainer != nil {
            items.append((tail.block, tail.level))
            let rect = extraLineFragmentRect
            let font = NotesLook.body
            let baseline = rect.minY + font.ascender + (tail.block == .title ? 0 : 0)
            let number = NotesMarkdown.numbers(items).last ?? nil
            drawMarker(tail, number: number, baseline: baseline, font: font, location: ns.length, origin: origin)
        }
    }

    /// Inline code on a rounded chip 3 pt wider than its text each side, one per line it runs over.
    private func drawCodeSpans(in chars: NSRange, container: NSTextContainer, origin: NSPoint) {
        guard let storage = textStorage, chars.length > 0 else { return }
        NotesLook.chip.setFill()
        storage.enumerateAttribute(.notesCode, in: chars) { value, run, _ in
            guard value != nil, let font = storage.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont,
                  NotesParagraph(storage.attributes(at: run.location, effectiveRange: nil)).block != .mono else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(glyphs, lineGlyphs)
                guard part.length > 0 else { return }
                let bounds = self.boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + self.location(forGlyphAt: part.location).y
                let rect = NSRect(x: origin.x + bounds.minX - 3, y: origin.y + baseline - font.ascender - 1,
                                  width: bounds.width + 6, height: font.ascender - font.descender + 2)
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    private func drawRun(_ block: NotesBlock, from first: NSRange, to last: NSRange, width: CGFloat, origin: NSPoint) {
        guard let top = firstLine(first), let bottom = lastBaseline(last) else { return }
        let font = block == .mono ? NotesLook.mono : NotesLook.body
        if block == .mono {
            let rect = NSRect(x: origin.x, y: origin.y + top.baseline - font.ascender - 6,
                              width: width, height: bottom - top.baseline + font.ascender - font.descender + 12)
            NotesLook.chip.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        } else {
            let rect = NSRect(x: origin.x, y: origin.y + top.baseline - font.ascender - 2,
                              width: 3, height: bottom - top.baseline + font.ascender - font.descender + 4)
            NotesLook.quoteBar.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawMarker(_ format: NotesParagraph, number: Int?, baseline: CGFloat, font: NSFont, location: Int, origin: NSPoint) {
        let indent = NotesLook.indent(format)
        let y = origin.y + baseline
        if format.block == .check {
            let center = NSPoint(x: origin.x + indent - 22 + 7.5, y: y - 4.3)
            let circle = NSRect(x: center.x - 7.5, y: center.y - 7.5, width: 15, height: 15)
            var fill: CGFloat = format.checked ? 1 : 0
            if let tick, tick.location == location { fill = format.checked ? tick.progress : 1 - tick.progress }
            if fill > 0 {
                NSColor.controlAccentColor.withAlphaComponent(fill).setFill()
                NSBezierPath(ovalIn: circle).fill()
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: center.x - 3.4, y: center.y + 0.1))
                mark.line(to: NSPoint(x: center.x - 0.9, y: center.y + 2.6))
                mark.line(to: NSPoint(x: center.x + 3.5, y: center.y - 2.6))
                mark.lineWidth = 1.6
                mark.lineCapStyle = .round
                mark.lineJoinStyle = .round
                NSColor.white.withAlphaComponent(fill).setStroke()
                mark.stroke()
            }
            if fill < 1 {
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                NotesLook.box.blended(withFraction: fill, of: NSColor.controlAccentColor)?.setStroke()
                ring.stroke()
            }
            return
        }
        if format.block == .bullet {
            // A disc, and a ring one level in, as Notes draws them.
            let dot = NSRect(x: origin.x + indent - 13, y: y - 4.3 - 2.5, width: 5, height: 5)
            if format.level % 2 == 0 {
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                NSColor.labelColor.setStroke()
                ring.stroke()
            }
            return
        }
        let label = format.block == .number ? "\(number ?? 1)." : "–"
        let markerFont = format.block == .number ? NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular) : NotesLook.body
        let attributes: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: NSColor.labelColor]
        let size = (label as NSString).size(withAttributes: attributes)
        let right = origin.x + indent - (format.block == .number ? 5 : 7)
        (label as NSString).draw(at: NSPoint(x: right - size.width, y: y - markerFont.ascender), withAttributes: attributes)
    }
}
