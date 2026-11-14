import AppKit

extension NSAttributedString.Key {
    // Per paragraph.
    static let notesBlock = NSAttributedString.Key("MinutesNotesBlock")
    static let notesLevel = NSAttributedString.Key("MinutesNotesLevel")
    static let notesChecked = NSAttributedString.Key("MinutesNotesChecked")
    static let notesFence = NSAttributedString.Key("MinutesNotesFence")
    // Per character.
    static let notesBold = NSAttributedString.Key("MinutesNotesBold")
    static let notesItalic = NSAttributedString.Key("MinutesNotesItalic")
    static let notesUnderline = NSAttributedString.Key("MinutesNotesUnderline")
    static let notesStrike = NSAttributedString.Key("MinutesNotesStrike")
    static let notesCode = NSAttributedString.Key("MinutesNotesCode")
    static let notesLink = NSAttributedString.Key("MinutesNotesLink")
    static let notesRaw = NSAttributedString.Key("MinutesNotesRaw")
}

/// A paragraph's format as kept on its characters.
struct NotesParagraph: Equatable {
    var block = NotesBlock.body
    var level = 0
    var checked = false
    var fence: String?

    static let keys: [NSAttributedString.Key] = [.notesBlock, .notesLevel, .notesChecked, .notesFence]
    static let inlineKeys: [NSAttributedString.Key] = [.notesBold, .notesItalic, .notesUnderline, .notesStrike, .notesCode, .notesLink, .notesRaw]

    init(block: NotesBlock = .body, level: Int = 0, checked: Bool = false, fence: String? = nil) {
        self.block = block
        self.level = level
        self.checked = checked
        self.fence = fence
    }

    init(_ attributes: [NSAttributedString.Key: Any]) {
        block = (attributes[.notesBlock] as? String).flatMap(NotesBlock.init(rawValue:)) ?? .body
        level = (attributes[.notesLevel] as? Int) ?? 0
        checked = (attributes[.notesChecked] as? Bool) ?? false
        fence = attributes[.notesFence] as? String
    }

    var attributes: [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [:]
        if block != .body { out[.notesBlock] = block.rawValue }
        if block.isList, level > 0 { out[.notesLevel] = level }
        if block == .check, checked { out[.notesChecked] = true }
        if block == .mono, let fence { out[.notesFence] = fence }
        return out
    }
}

extension NotesInline {
    init(_ attributes: [NSAttributedString.Key: Any]) {
        self.init(bold: attributes[.notesBold] != nil, italic: attributes[.notesItalic] != nil,
                  underline: attributes[.notesUnderline] != nil, strike: attributes[.notesStrike] != nil,
                  code: attributes[.notesCode] != nil, link: attributes[.notesLink] as? String, raw: attributes[.notesRaw] != nil)
    }

    var attributes: [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [:]
        if bold { out[.notesBold] = true }
        if italic { out[.notesItalic] = true }
        if underline { out[.notesUnderline] = true }
        if strike { out[.notesStrike] = true }
        if code { out[.notesCode] = true }
        if let link { out[.notesLink] = link }
        if raw { out[.notesRaw] = true }
        return out
    }
}

// MARK: Look

/// What notes look like: the board's 13 pt body, headings, lists, quotes and code.
enum NotesLook {
    static let body = NSFont.systemFont(ofSize: 13)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static let text2 = NSColor(name: nil) { $0.isDark ? NSColor(white: 0.82, alpha: 1) : NSColor(red: 0.259, green: 0.259, blue: 0.271, alpha: 1) }
    static let chip = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(red: 0.941, green: 0.941, blue: 0.953, alpha: 1) }
    /// A tag on a line of text, a step darker than a chip: #e8e8ed.
    static let tag = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.16) : NSColor(red: 0.91, green: 0.91, blue: 0.929, alpha: 1) }
    static let quoteBar = NSColor(name: nil) { $0.isDark ? NSColor(red: 0.353, green: 0.353, blue: 0.369, alpha: 1) : NSColor(red: 0.78, green: 0.78, blue: 0.8, alpha: 1) }
    static let menu = NSColor(name: nil) { $0.isDark ? NSColor(red: 0.165, green: 0.165, blue: 0.173, alpha: 1) : NSColor(red: 0.965, green: 0.965, blue: 0.973, alpha: 1) }
    static let box = NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)

    static func font(_ block: NotesBlock, _ style: NotesInline) -> NSFont {
        if block == .mono || style.code { return mono }
        var size: CGFloat = 13
        var weight = NSFont.Weight.regular
        switch block {
        case .title: size = 19; weight = .bold
        case .heading: size = 15; weight = .bold
        case .subheading: size = 13.5; weight = .semibold
        default: if style.bold { weight = .bold }
        }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard style.italic else { return font }
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    /// Where a paragraph's text starts.
    static func indent(_ paragraph: NotesParagraph) -> CGFloat {
        switch paragraph.block {
        case .bullet, .dash, .number: return 21 + 20 * CGFloat(paragraph.level)
        case .check: return 23 + 22 * CGFloat(paragraph.level)
        case .quote: return 13
        case .mono: return 8
        default: return 0
        }
    }

    static func paragraphStyle(_ paragraph: NotesParagraph, previous: NotesBlock?, next: NotesBlock?, picture: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = indent(paragraph)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.lineSpacing = 4
        switch paragraph.block {
        case .title:
            style.lineSpacing = 2
            style.paragraphSpacingBefore = previous == nil ? 0 : 8
            style.paragraphSpacing = 4
        case .heading:
            style.lineSpacing = 2
            style.paragraphSpacingBefore = previous == nil ? 0 : 12
            style.paragraphSpacing = 2
        case .subheading:
            style.lineSpacing = 3
            style.paragraphSpacingBefore = previous == nil ? 0 : 10
            style.paragraphSpacing = 2
        case .quote:
            style.paragraphSpacingBefore = previous == nil || previous == .quote ? 0 : 4
            style.paragraphSpacing = next == .quote ? 0 : 4
        case .mono:
            style.lineSpacing = 4
            style.tailIndent = -8
            style.paragraphSpacingBefore = previous == .mono ? 0 : previous == nil ? 6 : 10
            style.paragraphSpacing = next == .mono ? 0 : 10
        case .bullet, .dash, .number, .check:
            style.paragraphSpacing = 2
        case .body:
            if picture { style.paragraphSpacing = 4 }
        }
        return style
    }

    static func attributes(_ paragraph: NotesParagraph, _ style: NotesInline, paragraphStyle: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var out = paragraph.attributes.merging(style.attributes) { a, _ in a }
        out[.font] = font(paragraph.block, style)
        out[.paragraphStyle] = paragraphStyle
        let dimmed = paragraph.block == .check && paragraph.checked
        out[.foregroundColor] = style.link != nil && paragraph.block != .mono ? NSColor.controlAccentColor
            : dimmed ? NSColor.secondaryLabelColor : paragraph.block == .quote ? text2 : NSColor.labelColor
        if paragraph.block != .mono {
            if style.underline { out[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strike { out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        }
        return out
    }

    static let displayKeys: [NSAttributedString.Key] = [.font, .paragraphStyle, .foregroundColor, .underlineStyle, .strikethroughStyle, .backgroundColor]
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

// MARK: Conversion

extension NotesMarkdown {
    /// The lines as styled text; pictures become attachments drawn by `PictureCell`.
    static func attributed(_ lines: [NotesLine], folder: URL?, canPlay: Bool) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let paragraph = NotesParagraph(block: line.block, level: line.level, checked: line.checked, fence: line.fence)
            let previous = index > 0 ? lines[index - 1].block : nil
            let next = index + 1 < lines.count ? lines[index + 1].block : nil
            let style = NotesLook.paragraphStyle(paragraph, previous: previous, next: next, picture: line.picture != nil)
            let start = out.length
            if let source = line.picture, let picture = NotesAttachments.pictureLine(source) {
                let attachment = NSTextAttachment()
                let url = (folder ?? URL(fileURLWithPath: "/")).appendingPathComponent(picture.path)
                let own = NotesAttachments.isAttachment(picture.path)
                attachment.attachmentCell = PictureCell(
                    source: source, look: PictureLook(url: url, path: picture.path, time: own ? nil : Frames.time(of: picture.path), canPlay: canPlay && !own),
                    natural: own ? NotesAttachments.size(of: url) ?? NSSize(width: 320, height: 180) : nil)
                out.append(NSAttributedString(attachment: attachment))
                out.addAttributes(NotesLook.attributes(paragraph, NotesInline(), paragraphStyle: style), range: NSRange(location: start, length: 1))
            } else if line.block == .mono {
                out.append(NSAttributedString(string: line.text, attributes: NotesLook.attributes(paragraph, NotesInline(), paragraphStyle: style)))
            } else {
                for run in line.runs {
                    out.append(NSAttributedString(string: run.text, attributes: NotesLook.attributes(paragraph, run.style, paragraphStyle: style)))
                }
            }
            if index + 1 < lines.count {
                out.append(NSAttributedString(string: "\n", attributes: NotesLook.attributes(paragraph, NotesInline(), paragraphStyle: style)))
            }
        }
        return out
    }

    /// The format of an empty last line, which the text cannot hold; the editor keeps it beside the text.
    static func tail(_ lines: [NotesLine]) -> NotesParagraph? {
        guard let last = lines.last, last.runs.isEmpty, last.picture == nil, last.block != .body else { return nil }
        return NotesParagraph(block: last.block, level: last.level, checked: last.checked, fence: last.fence)
    }

    /// The editor's text as lines. A picture that ended up beside text still writes its own line.
    static func lines(_ text: NSAttributedString, tail: NotesParagraph? = nil) -> [NotesLine] {
        let ns = text.string as NSString
        var out: [NotesLine] = []
        var location = 0
        repeat {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var content = range
            if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
            let anchor = range.length > 0 ? range.location : max(0, range.location - 1)
            let paragraph = text.length > 0 && range.length > 0 ? NotesParagraph(text.attributes(at: anchor, effectiveRange: nil)) : NotesParagraph()
            let line = NotesLine(block: paragraph.block, level: paragraph.block.isList ? paragraph.level : 0,
                                 checked: paragraph.block == .check && paragraph.checked, fence: paragraph.block == .mono ? paragraph.fence : nil)
            var pending = line
            var hasText = false
            text.enumerateAttributes(in: content) { attributes, run, _ in
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    for _ in 0..<run.length {
                        if let cell = attachment.attachmentCell as? PictureCell {
                            if hasText { out.append(pending); pending = line; hasText = false }
                            out.append(NotesLine(picture: cell.source))
                        }
                    }
                    return
                }
                let piece = ns.substring(with: run).replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !piece.isEmpty else { return }
                hasText = true
                pending.runs.append(NotesRun(text: piece, style: paragraph.block == .mono ? NotesInline() : NotesInline(attributes)))
            }
            let pictures = out.last?.picture != nil && content.length > 0 && !hasText
            if hasText || !pictures { out.append(pending) }
            location = NSMaxRange(range)
        } while location < ns.length
        if ns.length > 0, ns.character(at: ns.length - 1) == 0x0A { out.append(NotesLine()) }
        if let tail, var last = out.last, last.runs.isEmpty, last.picture == nil {
            last.block = tail.block
            last.level = tail.block.isList ? tail.level : 0
            last.checked = tail.block == .check && tail.checked
            last.fence = tail.block == .mono ? tail.fence : nil
            out[out.count - 1] = last
        }
        return out
    }

    static func markdown(_ text: NSAttributedString, tail: NotesParagraph? = nil) -> String {
        serialize(lines(text, tail: tail))
    }
}
