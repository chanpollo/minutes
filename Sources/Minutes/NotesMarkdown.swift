import AppKit

/// What a notes line is. One editor line is one line of notes.md.
enum NotesBlock: String {
    case body, title, heading, subheading, mono, quote, bullet, dash, number, check

    var isList: Bool { self == .bullet || self == .dash || self == .number || self == .check }
    var isHeading: Bool { self == .title || self == .heading || self == .subheading }
}

struct NotesInline: Hashable {
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var code = false
    var link: String?
    /// Image syntax inside a line, `![…](…)`: shown and written back as it is.
    var raw = false
}

struct NotesRun: Equatable {
    var text: String
    var style = NotesInline()
}

struct NotesLine: Equatable {
    var block = NotesBlock.body
    var level = 0
    var checked = false
    /// The info string of a fenced block, e.g. `swift`.
    var fence: String?
    /// A Capture picture: the line as it stands in notes.md.
    var picture: String?
    var runs: [NotesRun] = []

    var text: String { runs.map(\.text).joined() }
}

/// notes.md as lines and back. The file stays plain Markdown: `#`–`###`, `**b**`, `*i*`, `<u>u</u>`, `~~s~~`,
/// `* ` bulleted, `- ` dashed, `1.` numbered, `- [ ]`/`- [x]`, `> `, `[t](url)`, `` `code` ``, fences and
/// `![hh:mm:ss](frames/…)` and `![](attachments/…)` pictures. Saving what was loaded gives the same file back.
enum NotesMarkdown {
    private enum Kind { case paragraph, heading, list, quote, fence, picture }

    // Blank lines: one after headings, pictures, fences, lists and quotes, and one before headings, pictures and fences.
    private static func separated(_ previous: Kind, _ next: Kind) -> Bool {
        after(previous) || before(next)
    }
    private static func after(_ kind: Kind) -> Bool { kind != .paragraph }
    private static func before(_ kind: Kind) -> Bool { kind == .heading || kind == .picture || kind == .fence }

    private static func kind(_ line: NotesLine) -> Kind {
        if line.picture != nil { return .picture }
        switch line.block {
        case .body: return .paragraph
        case .title, .heading, .subheading: return .heading
        case .mono: return .fence
        case .quote: return .quote
        case .bullet, .dash, .number, .check: return .list
        }
    }

    // MARK: Reading

    static func parse(_ markdown: String) -> [NotesLine] {
        var source = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if source.last == "" { source.removeLast() }
        var out: [NotesLine] = []
        var previous: Kind?
        var blanks = 0
        var indents: [Int] = []
        var index = 0

        func emit(_ lines: [NotesLine], _ kind: Kind) {
            let empty: Int
            if let previous {
                if !separated(previous, kind) || blanks == 0 {
                    empty = blanks
                } else if after(previous) {
                    empty = blanks - 1
                } else {
                    // After a paragraph one blank line is the separator, and an empty line before it would be too.
                    empty = blanks == 1 ? 0 : blanks
                }
            } else {
                empty = blanks
            }
            out += Array(repeating: NotesLine(), count: empty)
            out += lines
            if kind != .list { indents = [] }
            previous = kind
            blanks = 0
        }

        while index < source.count {
            let line = source[index]
            index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blanks += 1
                continue
            }
            if let fence = fenceOpening(line) {
                var lines: [NotesLine] = []
                while index < source.count {
                    let inner = source[index]
                    index += 1
                    if closesFence(inner, fence.marker) { break }
                    lines.append(NotesLine(block: .mono, fence: fence.info, runs: inner.isEmpty ? [] : [NotesRun(text: inner)]))
                }
                if lines.isEmpty { lines = [NotesLine(block: .mono, fence: fence.info)] }
                emit(lines, .fence)
            } else if NotesAttachments.pictureLine(line) != nil {
                emit([NotesLine(picture: line)], .picture)
            } else if let heading = match(headingPattern, line) {
                let level = heading[1]!.count
                let block: NotesBlock = level == 1 ? .title : level == 2 ? .heading : .subheading
                emit([NotesLine(block: block, runs: inline(heading[2] ?? ""))], .heading)
            } else if let item = match(listPattern, line) {
                let spaces = item[1]!.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                while let last = indents.last, spaces < last { indents.removeLast() }
                if indents.last.map({ spaces > $0 }) ?? true { indents.append(spaces) }
                let marker = item[2]!
                var content = item[3] ?? ""
                var block: NotesBlock = marker == "-" ? .dash : (marker == "*" || marker == "+") ? .bullet : .number
                var checked = false
                if block != .number, let box = match(checkPattern, content) {
                    block = .check
                    checked = box[1] != " "
                    content = box[2] ?? ""
                }
                emit([NotesLine(block: block, level: indents.count - 1, checked: checked, runs: inline(content))], .list)
            } else if line.hasPrefix(">") {
                var content = String(line.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                emit([NotesLine(block: .quote, runs: inline(content))], .quote)
            } else {
                emit([NotesLine(runs: inline(line))], .paragraph)
            }
        }
        return out
    }

    // Levels 4 to 6 have no style here; they stay paragraphs and are written back as they were.
    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,3})(?:[ \t]+(.*))?$"#)
    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d{1,9}[.)])(?:[ \t]+(.*))?$"#)
    private static let checkPattern = try! NSRegularExpression(pattern: #"^\[([ xX])\](?:[ \t]+(.*))?$"#)
    private static let fencePattern = try! NSRegularExpression(pattern: #"^(`{3,}|~{3,})[ \t]*(.*?)[ \t]*$"#)

    private static func match(_ pattern: NSRegularExpression, _ line: String) -> [String?]? {
        let ns = line as NSString
        guard let found = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<found.numberOfRanges).map { i in
            let range = found.range(at: i)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    private static func fenceOpening(_ line: String) -> (marker: String, info: String?)? {
        guard let found = match(fencePattern, line), let marker = found[1] else { return nil }
        let info = found[2] ?? ""
        if marker.hasPrefix("`") && info.contains("`") { return nil }
        return (marker, info.isEmpty ? nil : info)
    }

    private static func closesFence(_ line: String, _ marker: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let char = marker.first, trimmed.count >= marker.count else { return false }
        return trimmed.allSatisfy { $0 == char } && line.prefix { $0 == " " }.count < 4
    }

    // MARK: Inline

    private enum Mark: Equatable { case bold, italic, strike, underline, link }

    private struct Opener {
        let mark: Mark
        let id: Int
        let literal: String
        let piece: Int
        let active: [Int]
        var delimiter: Character?
    }

    /// Styled runs from one line's inline Markdown. Markers that never close stay as text.
    static func inline(_ text: String) -> [NotesRun] {
        let chars = Array(text)
        var pieces: [(text: String, active: [Int], code: Bool, raw: Bool)] = []
        var stack: [Opener] = []
        var links: [Int: String] = [:]
        var marks: [Int: Mark] = [:]
        var closed = Set<Int>()
        var nextID = 0
        var i = 0

        func add(_ s: String, code: Bool = false, raw: Bool = false) {
            guard !s.isEmpty else { return }
            let active = stack.map(\.id)
            if !code, !raw, let last = pieces.last, !last.code, !last.raw, last.active == active {
                pieces[pieces.count - 1].text += s
            } else {
                pieces.append((s, active, code, raw))
            }
        }
        func open(_ mark: Mark, _ literal: String, delimiter: Character? = nil) {
            marks[nextID] = mark
            stack.append(Opener(mark: mark, id: nextID, literal: literal, piece: pieces.count, active: stack.map(\.id), delimiter: delimiter))
            nextID += 1
        }
        // A pair with nothing between stays text, so no characters are lost.
        func close(_ literal: String) {
            guard let top = stack.popLast() else { return }
            if top.piece == pieces.count { add(top.literal + literal) } else { closed.insert(top.id) }
        }
        func has(_ mark: Mark) -> Bool { stack.contains { $0.mark == mark } }
        func isSpace(_ c: Character?) -> Bool { c.map { $0.isWhitespace } ?? true }
        func run(of c: Character, from start: Int) -> Int {
            var n = 0
            while start + n < chars.count, chars[start + n] == c { n += 1 }
            return n
        }
        func starts(_ s: String, at index: Int) -> Bool {
            let target = Array(s)
            guard index + target.count <= chars.count else { return false }
            return chars[index..<index + target.count].map { $0.lowercased() } == target.map { $0.lowercased() }
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                add(String(chars[i + 1]))
                i += 2
            } else if c == "`" {
                let n = run(of: "`", from: i)
                var j = i + n
                var end: Int?
                while j < chars.count {
                    if chars[j] == "`" {
                        let m = run(of: "`", from: j)
                        if m == n { end = j; break }
                        j += m
                    } else {
                        j += 1
                    }
                }
                if let end {
                    var content = String(chars[(i + n)..<end])
                    if content.count >= 2, content.first == " ", content.last == " ", content.contains(where: { $0 != " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    add(content, code: true)
                    i = end + n
                } else {
                    add(String(repeating: "`", count: n))
                    i += n
                }
            } else if c == "*" || c == "_" {
                let n = run(of: c, from: i)
                let before = i > 0 ? chars[i - 1] : nil
                let after = i + n < chars.count ? chars[i + n] : nil
                var canOpen = !isSpace(after)
                var canClose = !isSpace(before)
                if c == "_", let before, let after, before.isLetter || before.isNumber, after.isLetter || after.isNumber {
                    canOpen = false
                    canClose = false
                }
                var left = n
                while canClose, left > 0, let top = stack.last, top.delimiter == c {
                    // `*a**b***`: a pair after an open italic opens bold rather than closing and reopening italic.
                    if top.mark == .italic, left == 2, canOpen, !has(.bold) { break }
                    if top.mark == .italic { close(String(c)); left -= 1 } else if top.mark == .bold, left >= 2 { close(String(repeating: c, count: 2)); left -= 2 } else { break }
                }
                let bold = canOpen && left >= 2 && !has(.bold)
                let italic = canOpen && left - (bold ? 2 : 0) >= 1 && !has(.italic)
                add(String(repeating: c, count: left - (bold ? 2 : 0) - (italic ? 1 : 0)))
                if bold { open(.bold, String(repeating: c, count: 2), delimiter: c) }
                if italic { open(.italic, String(c), delimiter: c) }
                i += n
            } else if c == "~", i + 1 < chars.count, chars[i + 1] == "~" {
                let before = i > 0 ? chars[i - 1] : nil
                let after = i + 2 < chars.count ? chars[i + 2] : nil
                if !isSpace(before), stack.last?.mark == .strike {
                    close("~~")
                } else if !isSpace(after), !has(.strike) {
                    open(.strike, "~~")
                } else {
                    add("~~")
                }
                i += 2
            } else if c == "<", starts("<u>", at: i), !has(.underline) {
                open(.underline, String(chars[i..<i + 3]))
                i += 3
            } else if c == "<", starts("</u>", at: i), stack.last?.mark == .underline {
                close(String(chars[i..<i + 4]))
                i += 4
            } else if c == "!", let end = imageEnd(chars, from: i) {
                add(String(chars[i...end]), raw: true)
                i = end + 1
            } else if c == "[" {
                open(.link, "[")
                i += 1
            } else if c == "]", stack.last?.mark == .link, i + 1 < chars.count, chars[i + 1] == "(",
                      let end = chars[(i + 2)...].firstIndex(where: { $0 == ")" || $0.isWhitespace }), chars[end] == ")", end > i + 2 {
                links[stack.last!.id] = String(chars[(i + 2)..<end]).replacingOccurrences(of: "%20", with: " ")
                    .replacingOccurrences(of: "%28", with: "(").replacingOccurrences(of: "%29", with: ")")
                close(String(chars[i...end]))
                i = end + 1
            } else {
                add(String(c))
                i += 1
            }
        }

        // Unclosed markers go back in as text, innermost first so earlier positions stay put.
        for opener in stack.reversed() {
            pieces.insert((opener.literal, opener.active, false, false), at: opener.piece)
        }
        var runs: [NotesRun] = []
        for piece in pieces where !piece.text.isEmpty {
            var style = NotesInline(code: piece.code, raw: piece.raw)
            for id in piece.active where closed.contains(id) {
                switch marks[id] {
                case .bold: style.bold = true
                case .italic: style.italic = true
                case .strike: style.strike = true
                case .underline: style.underline = true
                case .link: style.link = links[id]
                case nil: break
                }
            }
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += piece.text
            } else {
                runs.append(NotesRun(text: piece.text, style: style))
            }
        }
        return runs
    }

    /// The last index of `![alt](target)` starting at `start`, alt without `]`, target without spaces.
    private static func imageEnd(_ chars: [Character], from start: Int) -> Int? {
        guard start + 1 < chars.count, chars[start + 1] == "[",
              let close = chars[(start + 2)...].firstIndex(where: { $0 == "]" || $0 == "\n" }), chars[close] == "]",
              close + 1 < chars.count, chars[close + 1] == "(",
              let end = chars[(close + 2)...].firstIndex(where: { $0 == ")" || $0.isWhitespace }), chars[end] == ")", end > close + 2
        else { return nil }
        return end
    }

    // MARK: Writing

    static func serialize(_ lines: [NotesLine]) -> String {
        var out: [String] = []
        var index = 0
        var previous: Kind?
        while index < lines.count {
            let kind = kind(lines[index])
            var end = index + 1
            if kind == .list || kind == .quote || kind == .fence {
                while end < lines.count, Self.kind(lines[end]) == kind { end += 1 }
            }
            let block = Array(lines[index..<end])
            if let previous, separated(previous, kind), out.last != "" { out.append("") }
            switch kind {
            case .picture: out.append(block[0].picture ?? "")
            case .heading:
                let marks = block[0].block == .title ? "#" : block[0].block == .heading ? "##" : "###"
                let text = trimmedStart(emit(block[0].runs))
                out.append(text.isEmpty ? marks : marks + " " + text)
            case .quote: out += block.map { line in
                let text = emit(line.runs)
                return text.isEmpty ? ">" : "> " + text
            }
            case .fence:
                let body = block.map(\.text)
                // Backticks in the info string need a tilde fence.
                let fenceChar: Character = (block[0].fence ?? "").contains("`") ? "~" : "`"
                let longest = body.map { longestRun(of: fenceChar, in: $0) }.max() ?? 0
                let marker = String(repeating: fenceChar, count: max(3, longest + 1))
                out.append(marker + (block[0].fence ?? ""))
                out += body
                out.append(marker)
            case .list: out += listLines(block)
            case .paragraph: out.append(paragraphLine(emit(block[0].runs)))
            }
            previous = kind
            index = end
        }
        while out.last == "" { out.removeLast() }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    /// The number each numbered item shows, nil for other lines; numbering restarts after anything else at its level.
    static func numbers(_ items: [(block: NotesBlock, level: Int)]) -> [Int?] {
        var counters: [Int: Int] = [:]
        var kinds: [Int: NotesBlock] = [:]
        return items.map { item in
            guard item.block.isList else {
                counters = [:]
                kinds = [:]
                return nil
            }
            for level in Array(kinds.keys) where level > item.level {
                kinds[level] = nil
                counters[level] = nil
            }
            let continues = kinds[item.level] == item.block
            kinds[item.level] = item.block
            guard item.block == .number else { return nil }
            let n = continues ? (counters[item.level] ?? 0) + 1 : 1
            counters[item.level] = n
            return n
        }
    }

    private static func listLines(_ items: [NotesLine]) -> [String] {
        let numbers = numbers(items.map { ($0.block, $0.level) })
        var parents: [(level: Int, child: String)] = []
        return items.enumerated().map { index, item in
            while let last = parents.last, last.level >= item.level { parents.removeLast() }
            let missing = item.level - (parents.last.map { $0.level + 1 } ?? 0)
            let indent = (parents.last?.child ?? "") + String(repeating: "  ", count: max(0, missing))
            let marker: String
            switch item.block {
            case .number: marker = "\(numbers[index] ?? 1)."
            case .check: marker = item.checked ? "- [x]" : "- [ ]"
            case .dash: marker = "-"
            default: marker = "*"
            }
            let child = indent + String(repeating: " ", count: item.block == .check ? 2 : marker.count + 1)
            parents.append((item.level, child))
            let text = trimmedStart(emit(item.runs))
            return indent + marker + (text.isEmpty ? "" : " " + text)
        }
    }

    private static func trimmedStart(_ s: String) -> String {
        String(s.drop { $0 == " " || $0 == "\t" })
    }

    private static func longestRun(of c: Character, in s: String) -> Int {
        var best = 0, current = 0
        for x in s {
            current = x == c ? current + 1 : 0
            best = max(best, current)
        }
        return best
    }

    /// A paragraph that would read as a heading, list item, quote or fence gets its first marker escaped.
    private static func paragraphLine(_ line: String) -> String {
        let lead = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(lead.count)
        if match(listMarkerStart, String(rest)) != nil {
            if let first = rest.first, first == "-" || first == "+" { return lead + "\\" + rest }
            if let dot = rest.firstIndex(where: { $0 == "." || $0 == ")" }) {
                return lead + rest[..<dot] + "\\" + rest[dot...]
            }
        }
        if lead.isEmpty, match(headingPattern, line) != nil || line.hasPrefix(">") { return "\\" + line }
        return line
    }

    private static let listMarkerStart = try! NSRegularExpression(pattern: #"^([-+]|\d{1,9}[.)])(?:[ \t]|$)"#)

    private static let order: [Mark] = [.link, .bold, .italic, .strike, .underline]

    private static func marks(_ style: NotesInline) -> [Mark] {
        order.filter { mark in
            switch mark {
            case .link: return style.link != nil
            case .bold: return style.bold
            case .italic: return style.italic
            case .strike: return style.strike
            case .underline: return style.underline
            }
        }
    }

    /// Inline Markdown for styled runs. Markers open in a fixed order and never start or end next to a space.
    static func emit(_ runs: [NotesRun]) -> String {
        var merged: [NotesRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = merged.last, last.style == run.style { merged[merged.count - 1].text += run.text } else { merged.append(run) }
        }
        var out = ""
        var open: [Mark] = []
        var href: String?

        func closing(_ mark: Mark) -> String {
            switch mark {
            case .link:
                let url = (href ?? "").replacingOccurrences(of: " ", with: "%20")
                    .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                return "](" + url + ")"
            case .bold: return "**"
            case .italic: return "*"
            case .strike: return "~~"
            case .underline: return "</u>"
            }
        }
        func opening(_ mark: Mark) -> String {
            switch mark {
            case .link: return "["
            case .bold: return "**"
            case .italic: return "*"
            case .strike: return "~~"
            case .underline: return "<u>"
            }
        }
        func close(from: Int) {
            guard from < open.count else { return }
            let spaces = String(out.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            out.removeLast(spaces.count)
            for mark in open[from...].reversed() { out += closing(mark) }
            open.removeSubrange(from...)
            out += spaces
        }

        for run in merged {
            let need = marks(run.style)
            // Markers already open stay open while the run still has them; the rest open in the fixed order.
            var keep = 0
            while keep < open.count, need.contains(open[keep]), open[keep] != .link || href == run.style.link { keep += 1 }
            close(from: keep)
            let missing = need.filter { !open.contains($0) }
            if !run.style.code, run.text.allSatisfy({ $0 == " " || $0 == "\t" }) {
                out += run.text
                continue
            }
            var text = run.style.code ? codeSpan(run.text) : run.style.raw ? run.text
                : escape(run.text).replacingOccurrences(of: "~", with: String(tilde))
            if !missing.isEmpty {
                if !run.style.code {
                    let lead = text.prefix { $0 == " " || $0 == "\t" }
                    out += lead
                    text.removeFirst(lead.count)
                }
                for mark in missing {
                    // `!` before a link would make it a picture.
                    if mark == .link, out.last == "!" { out.insert("\\", at: out.index(before: out.endIndex)) }
                    out += opening(mark)
                    if mark == .link { href = run.style.link }
                }
                open += missing
            }
            out += text
        }
        close(from: 0)
        // A text tilde is escaped where it touches another tilde, so it never reads as part of `~~`.
        let chars = Array(out)
        var result = ""
        for (i, c) in chars.enumerated() {
            guard c == tilde else { result.append(c); continue }
            let touches = (i > 0 && (chars[i - 1] == "~" || chars[i - 1] == tilde)) || (i + 1 < chars.count && (chars[i + 1] == "~" || chars[i + 1] == tilde))
            result += touches ? "\\~" : "~"
        }
        return result
    }

    /// Stands in for a text tilde until the line is written, to tell it from the `~~` markers.
    private static let tilde: Character = "\u{E000}"

    private static func codeSpan(_ text: String) -> String {
        let fence = String(repeating: "`", count: longestRun(of: "`", in: text) + 1)
        let pad = text.first == "`" || text.last == "`"
            || (text.count >= 2 && text.first == " " && text.last == " " && text.contains { $0 != " " }) ? " " : ""
        return fence + pad + text + pad + fence
    }

    /// Backslashes the characters that would read as markers.
    static func escape(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        for (i, c) in chars.enumerated() {
            let before = i > 0 ? chars[i - 1] : nil
            let after = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "\\", "`", "*", "[", "]":
                out += "\\" + String(c)
            case "_":
                let inWord = before.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
                    && after.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
                out += inWord ? "_" : "\\_"
            case "<":
                let rest = String(chars[(i + 1)...].prefix(3)).lowercased()
                out += rest.hasPrefix("u>") || rest == "/u>" ? "\\<" : "<"
            default:
                out.append(c)
            }
        }
        return out
    }
}
