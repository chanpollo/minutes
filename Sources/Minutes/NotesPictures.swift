import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Pictures people add to Notes themselves: copied into the meeting's attachments/ and linked as
/// `![](attachments/<name>)` on a line of their own, as Capture's frames/ pictures are.
enum NotesAttachments {
    static let folderName = "attachments"

    private static let linePattern = try! NSRegularExpression(pattern: #"^!\[([^\]\n]*)\]\((attachments/[^)\s]+)\)$"#)

    /// A whole line that is a picture: Capture's frames/ or an attachment. Paths are relative to the meeting folder.
    static func pictureLine(_ line: String) -> (alt: String, path: String)? {
        if let frame = Frames.pictureLine(line) { return frame }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        guard let found = linePattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              let path = ns.substring(with: found.range(at: 2)).removingPercentEncoding, isSafe(path)
        else { return nil }
        return (ns.substring(with: found.range(at: 1)), path)
    }

    /// Only a file directly inside attachments/: nothing outside the meeting folder.
    private static func isSafe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let name = parts.last else { return false }
        return !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".")
    }

    private static let anyLinkPattern = try! NSRegularExpression(pattern: #"\]\((attachments/[^)\s]+)\)"#)

    static func isAttachment(_ path: String) -> Bool { path.hasPrefix(folderName + "/") }

    /// The Markdown line for a stored file name.
    static func line(for name: String) -> String {
        var encoded = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case " ": encoded += "%20"
            case "%": encoded += "%25"
            case "(": encoded += "%28"
            case ")": encoded += "%29"
            case "[": encoded += "%5B"
            case "]": encoded += "%5D"
            case "<": encoded += "%3C"
            case ">": encoded += "%3E"
            case "\\": encoded += "%5C"
            default:
                if scalar.properties.isWhitespace || scalar.value < 0x20 {
                    encoded += String(format: "%%%02X", scalar.value)
                } else {
                    encoded.unicodeScalars.append(scalar)
                }
            }
        }
        return "![](\(folderName)/\(encoded))"
    }

    /// The attachments notes.md links to anywhere, not only on lines of their own, as paths relative to the meeting
    /// folder, once each, in order.
    static func referenced(in markdown: String) -> [String] {
        var seen = Set<String>()
        let ns = markdown as NSString
        return anyLinkPattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).compactMap { found in
            ns.substring(with: found.range(at: 1)).removingPercentEncoding.flatMap { isSafe($0) ? $0 : nil }
        }.filter { seen.insert($0).inserted }
    }

    static func referenced(inFolder folder: URL) -> [String] {
        let text = (try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
        return referenced(in: text).filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    // MARK: Storing

    /// A file name that stays inside attachments/: no folders, no leading dots, no control characters.
    static func safeName(_ proposed: String, type: UTType?) -> String {
        var name = (proposed as NSString).lastPathComponent
        name = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0 != "\u{7F}" }.map(Character.init))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        var base = (name as NSString).deletingPathExtension
        var ext = (name as NSString).pathExtension
        if base.isEmpty { base = "Picture" }
        if ext.isEmpty || UTType(filenameExtension: ext).map({ !$0.conforms(to: .image) }) ?? true {
            ext = type.map(Self.ext) ?? "png"
        }
        if base.count > 120 { base = String(base.prefix(120)) }
        return base + "." + ext
    }

    /// Kept as they are; anything else (HEIC, TIFF, WebP…) is converted so any Markdown viewer shows it.
    private static let kept: [UTType] = [.png, .jpeg, .gif]

    /// Copies a picture into `folder`/attachments/ under a free name and returns its path relative to `folder`.
    static func store(_ data: Data, name proposed: String, in folder: URL) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) as String?
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(proposed) is not a picture Minutes can read."]) }
        let type = UTType(typeID)
        var bytes = data
        var target = type
        if let type, !kept.contains(type) {
            // Photos become JPEG, the rest PNG; orientation and other metadata go along.
            target = type.conforms(to: .heic) || type.conforms(to: .heif) || type == .jpeg ? .jpeg : .png
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, target!.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            bytes = out as Data
        }
        var name = safeName(proposed, type: target)
        if let target, let ext = Optional(Self.ext(target)),
           UTType(filenameExtension: (name as NSString).pathExtension) != target {
            name = (name as NSString).deletingPathExtension + "." + ext
        }
        let directory = folder.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = free(name, in: directory)
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try bytes.write(to: url, options: .withoutOverwriting)
        return folderName + "/" + url.lastPathComponent
    }

    static func store(file: URL, in folder: URL) throws -> String {
        try store(try Data(contentsOf: file), name: file.lastPathComponent, in: folder)
    }

    private static func ext(_ type: UTType) -> String {
        type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "png"
    }

    /// `name`, or `name 2`, `name 3`… when taken.
    private static func free(_ name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    // MARK: Copying

    /// Pictures copied or cut out of Notes: each picture line with the file it shows, so a paste into another meeting
    /// copies the file, and a cut picture is not cleaned away while it is still on the pasteboard.
    static let pasteboardType = NSPasteboard.PasteboardType("com.enta1234.minutes.notes-pictures")

    static func copied(from pboard: NSPasteboard) -> [String: String] {
        (pboard.propertyList(forType: pasteboardType) as? [String: String]) ?? [:]
    }

    /// Deletes attachments notes.md no longer links to and returns their paths. frames/ is never touched, nor a picture
    /// still on the pasteboard.
    @discardableResult
    static func clean(_ folder: URL, keeping markdown: String) -> [String] {
        let directory = folder.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var used = Set(referenced(in: markdown).map { ($0 as NSString).lastPathComponent })
        for path in copied(from: .general).values {
            let url = URL(fileURLWithPath: path)
            if url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
                used.insert(url.lastPathComponent)
            }
        }
        var removed: [String] = []
        for name in names where !used.contains(name) && !name.hasPrefix(".") {
            if (try? fm.removeItem(at: directory.appendingPathComponent(name))) != nil { removed.append(folderName + "/" + name) }
        }
        if (try? fm.contentsOfDirectory(atPath: directory.path))?.isEmpty == true { try? fm.removeItem(at: directory) }
        return removed
    }

    /// Picture types on a pasteboard, best first.
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.heif.identifier),
        NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier), .tiff,
    ]

    /// The size a picture shows at, in points, before it is fitted to the column.
    static func size(of url: URL) -> NSSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat, let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0
        else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? CGFloat).map { max($0, 72) } ?? 72
        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let size = NSSize(width: width * 72 / dpi, height: height * 72 / dpi)
        return turned ? NSSize(width: size.height, height: size.width) : size
    }
}

/// Draws one notes picture across the column: thumbnail, border and, for Capture's frames, the time chip.
final class PictureCell: NSTextAttachmentCell {
    let source: String
    let look: PictureLook
    /// An attachment's own size; frames are drawn 16:9 across the column.
    let natural: NSSize?
    /// Where it was last drawn, in the text view.
    private(set) var frame = NSRect.zero
    var progress: CGFloat = 1
    var slides = true

    init(source: String, look: PictureLook, natural: NSSize? = nil) {
        self.source = source
        self.look = look
        self.natural = natural
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let top: CGFloat = 6, bottom: CGFloat = 4, tallest: CGFloat = 640

    var isAttachment: Bool { NotesAttachments.isAttachment(look.path) }

    private var aspect: CGFloat {
        guard let natural, natural.width > 0 else { return 9 / 16 }
        return natural.height / natural.width
    }

    var box: NSRect {
        NSRect(x: frame.minX, y: frame.minY + Self.top, width: frame.width, height: frame.width * aspect)
    }

    var chip: NSRect {
        let width = (clock as NSString?).map { ceil($0.size(withAttributes: [.font: Self.chipFont]).width) + 23 } ?? 0
        return NSRect(x: box.minX + 6, y: box.maxY - 26, width: width, height: 20)
    }

    private var clock: String? { look.time.map(MeetingFormat.longClock) }
    private static let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        var width = max(60, lineFrag.width - textContainer.lineFragmentPadding * 2)
        // Large pictures fit the column; small ones keep their size; tall ones stop at 640 pt.
        if let natural { width = max(24, min(width, natural.width, Self.tallest / aspect)) }
        return NSRect(x: 0, y: -Self.bottom, width: width, height: width * aspect + Self.top + Self.bottom)
    }

    override func cellSize() -> NSSize { NSSize(width: 240, height: 145) }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -Self.bottom) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        frame = cellFrame
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(progress)
        let rect = box.offsetBy(dx: 0, dy: slides ? -6 * (1 - progress) : 0)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        rect.fill()
        if let image = FrameThumbnails.image(look.url) {
            let scale = min(rect.width / image.size.width, rect.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: progress, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(0.1).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        border.lineWidth = 1
        border.stroke()

        guard let clock else { return }
        let chip = self.chip.offsetBy(dx: 0, dy: rect.minY - box.minY)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
        let triangle = NSBezierPath()
        let tx = chip.minX + 6, ty = chip.midY
        triangle.move(to: NSPoint(x: tx, y: ty - 3.5))
        triangle.line(to: NSPoint(x: tx + 6, y: ty))
        triangle.line(to: NSPoint(x: tx, y: ty + 3.5))
        triangle.close()
        NSColor.white.setFill()
        triangle.fill()
        let text = NSAttributedString(string: clock, attributes: [.font: Self.chipFont, .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: tx + 10, y: chip.midY - size.height / 2))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }
}
