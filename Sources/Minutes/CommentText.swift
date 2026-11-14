import AppKit
import os
import SwiftUI

/// A summary block or transcript line.
struct CommentUnit: Equatable {
    let target: CommentTarget
    let index: Int
}

struct TextHighlight: Equatable {
    let id: String
    let range: NSRange
    let active: Bool
    /// The composer's range: highlight colour, no underline.
    let pending: Bool
}

/// Yellow means a comment; blue stays selection and the playing row.
enum CommentColors {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static func highlight(dark: Bool, active: CGFloat) -> NSColor {
        dark ? rgb(255, 214, 10, 0.20 + 0.20 * active) : rgb(255, 204, 0, 0.30 + 0.28 * active)
    }

    static func underline(dark: Bool) -> NSColor {
        dark ? rgb(255, 214, 10, 0.80) : rgb(217, 164, 0)
    }

    static let quoteFill = dynamic(rgb(255, 204, 0, 0.30), rgb(255, 214, 10, 0.20))
    static let avatar = dynamic(rgb(232, 232, 237), rgb(48, 48, 50))
    static let card = dynamic(.white, rgb(44, 44, 46))
    static let quoteText = dynamic(rgb(66, 66, 69), rgb(209, 209, 214))
    static let hover = dynamic(rgb(235, 235, 240), rgb(44, 44, 46))
    static let pill = dynamic(rgb(29, 29, 31), rgb(245, 245, 247))
    static let onPill = dynamic(.white, rgb(29, 29, 31))
}

/// Inline Markdown (bold, italic, code, links) as the text view shows it; its characters are what comments anchor to.
enum InlineText {
    enum Style { case heading, summary, transcript }

    // The page queue builds these too, to typeset them ahead.
    private static let cache = OSAllocatedUnfairLock(uncheckedState: [String: NSAttributedString]())

    static func attributed(_ text: String, style: Style) -> NSAttributedString {
        let key = "\(style)\u{1}\(text)"
        if let cached = cache.withLockUnchecked({ $0[key] }) { return cached }
        let base = style == .heading ? NSFont.systemFont(ofSize: 14, weight: .semibold) : NSFont.systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing(style)
        // As SwiftUI's Text sets it: Thai falls back to a taller font, but lines keep the system font's height.
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let plain: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let result: NSAttributedString
        if style == .transcript {
            result = NSAttributedString(string: text, attributes: plain)
        } else if let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            let out = NSMutableAttributedString()
            for run in parsed.runs {
                var attributes = plain
                var font = base
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
                    if intent.contains(.stronglyEmphasized) { font = adding(.bold, to: font) }
                    if intent.contains(.emphasized) { font = adding(.italic, to: font) }
                    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                }
                attributes[.font] = font
                if let link = run.link { attributes[.link] = link }
                out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            result = out
        } else {
            result = NSAttributedString(string: text, attributes: plain)
        }
        return cache.withLockUnchecked { cache in
            if let raced = cache[key] { return raced }
            if cache.count > 4000 { cache.removeAll() }
            cache[key] = result
            return result
        }
    }

    // NSFontManager is for the main thread only.
    private static func adding(_ trait: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    static let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14))

    static func lineSpacing(_ style: Style) -> CGFloat {
        switch style {
        case .heading: return 0
        case .summary: return 6
        case .transcript: return 4
        }
    }
}

/// Summary text typeset on the page queue at the widths the page last gave each kind of block, so a newly
/// selected meeting's text views only take it over. Anything not ready, or at another width, is laid out as before.
enum TextPrep {
    final class Laid: @unchecked Sendable {
        let text: NSAttributedString
        // Holds the layout manager and container; nothing else does until a text view takes them.
        let storage: NSTextStorage
        let container: NSTextContainer
        let width: CGFloat
        let size: CGSize
        let baseline: CGFloat

        init(text: NSAttributedString, storage: NSTextStorage, container: NSTextContainer, width: CGFloat, size: CGSize, baseline: CGFloat) {
            (self.text, self.storage, self.container) = (text, storage, container)
            (self.width, self.size, self.baseline) = (width, size, baseline)
        }
    }

    private struct State {
        var widths: [String: CGFloat] = [:]
        var ready: [Laid] = []
    }

    private static let state = OSAllocatedUnfairLock(uncheckedState: State())

    static func remember(_ width: CGFloat, for key: String) {
        state.withLockUnchecked { $0.widths[key] = width }
    }

    static func width(for key: String) -> CGFloat? {
        state.withLockUnchecked { $0.widths[key] }
    }

    /// Any thread; the objects stay with that thread until `take` hands them to the main thread.
    static func prepare(_ text: NSAttributedString, width: CGFloat) {
        let storage = NSTextStorage(attributedString: text)
        let container = container(storage, width: width)
        guard let layout = container.layoutManager else { return }
        layout.backgroundLayoutEnabled = false
        let fit = measure(layout, container, width: width)
        let laid = Laid(text: text, storage: storage, container: container, width: width, size: fit.size, baseline: fit.baseline)
        state.withLockUnchecked { state in
            state.ready.append(laid)
            if state.ready.count > 300 { state.ready.removeFirst(state.ready.count - 300) }
        }
    }

    static func take(_ text: NSAttributedString) -> Laid? {
        state.withLockUnchecked { state in
            guard let index = state.ready.lastIndex(where: { $0.text === text }) else { return nil }
            return state.ready.remove(at: index)
        }
    }

    static func container(_ storage: NSTextStorage, width: CGFloat) -> NSTextContainer {
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return container
    }

    /// Size for `width` and the first line's baseline from the top. The container is left at `width`: the frame the
    /// view gets next is the same, so the text is not laid out twice.
    static func measure(_ layout: NSLayoutManager, _ container: NSTextContainer, width: CGFloat) -> (size: CGSize, baseline: CGFloat) {
        if container.size.width != width { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        var baseline = NSFont.systemFont(ofSize: 14).ascender
        // A Thai fallback font's leading adds a fraction under the last line that SwiftUI's Text leaves out.
        let height = floor(used.height + 0.05)
        if layout.numberOfGlyphs > 0 {
            let first = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            baseline = first.minY + layout.location(forGlyphAt: 0).y
        }
        return (CGSize(width: ceil(min(used.width, width)), height: ceil(max(height, 1))), baseline)
    }
}

final class BaselineBox {
    var baseline: CGFloat = 13
}

/// Summary and transcript text that can be selected by range and carries comment highlights.
struct SelectableText: View {
    let text: NSAttributedString
    let style: InlineText.Style
    let unit: CommentUnit
    let marks: [TextHighlight]
    let model: CommentsModel?
    var onClick: (() -> Void)?
    var menu: (() -> [NSMenuItem])?
    /// Remembers the width this kind of text was last given, for TextPrep.
    var widthKey: String?
    @State private var box = BaselineBox()

    var body: some View {
        CommentableText(text: text, lineSpacing: InlineText.lineSpacing(style), unit: unit, marks: marks, model: model,
                        onClick: onClick, menu: menu, box: box, widthKey: widthKey)
            .alignmentGuide(.firstTextBaseline) { _ in box.baseline }
    }
}

private struct CommentableText: NSViewRepresentable {
    let text: NSAttributedString
    let lineSpacing: CGFloat
    let unit: CommentUnit
    let marks: [TextHighlight]
    let model: CommentsModel?
    let onClick: (() -> Void)?
    let menu: (() -> [NSMenuItem])?
    let box: BaselineBox
    let widthKey: String?

    func makeNSView(context: Context) -> CommentTextView {
        let view = TextPrep.take(text).map { CommentTextView.make(adopting: $0, lineSpacing: lineSpacing) } ?? CommentTextView.make()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CommentTextView, context: Context) {
        view.setText(text, lineSpacing: lineSpacing)
        view.unit = unit
        view.model = model
        view.marks = marks
        view.onClick = onClick
        view.extraMenu = menu
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommentTextView, context: Context) -> CGSize? {
        let finite = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let fit = nsView.fit(width: finite ?? 100_000)
        if let widthKey, let finite { TextPrep.remember(finite, for: widthKey) }
        box.baseline = fit.baseline
        return CGSize(width: finite ?? fit.size.width, height: fit.size.height)
    }
}

/// Selectable, not editable; reports clicks, selections and highlight clicks to the comments model.
final class CommentTextView: NSTextView {
    var unit = CommentUnit(target: .summary, index: 0)
    weak var model: CommentsModel?
    var onClick: (() -> Void)?
    var extraMenu: (() -> [NSMenuItem])?
    private var source: NSAttributedString?
    private var spacing: CGFloat = 0
    private var measured: (width: CGFloat, size: CGSize, baseline: CGFloat)?

    var marks: [TextHighlight] = [] {
        didSet {
            guard marks != oldValue else { return }
            animate(from: oldValue)
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    static func make() -> CommentTextView {
        let storage = NSTextStorage()
        return withExtendedLifetime(storage) {
            make(container: TextPrep.container(storage, width: 100), frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        }
    }

    /// Takes over text the page queue already typeset, so it is not laid out again here.
    static func make(adopting laid: TextPrep.Laid, lineSpacing: CGFloat) -> CommentTextView {
        let view = withExtendedLifetime(laid.storage) {
            make(container: laid.container, frame: NSRect(origin: .zero, size: CGSize(width: laid.width, height: laid.size.height)))
        }
        view.source = laid.text
        view.spacing = lineSpacing
        view.measured = (laid.width, laid.size, laid.baseline)
        return view
    }

    private static func make(container: NSTextContainer, frame: NSRect) -> CommentTextView {
        let view = CommentTextView(frame: frame, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.usesFindBar = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        return view
    }

    func setText(_ text: NSAttributedString, lineSpacing: CGFloat) {
        guard text !== source else { return }
        source = text
        spacing = lineSpacing
        textStorage?.setAttributedString(text)
        measured = nil
    }

    /// Size for `width` and the first line's baseline from the top.
    func fit(width: CGFloat) -> (size: CGSize, baseline: CGFloat) {
        if let measured, abs(measured.width - width) < 0.5 { return (measured.size, measured.baseline) }
        guard let layout = layoutManager, let container = textContainer else { return (.zero, 13) }
        let fit = TextPrep.measure(layout, container, width: width)
        measured = (width, fit.size, fit.baseline)
        return fit
    }

    // MARK: Highlights

    private struct Fade {
        var from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval
        func value(_ now: CFTimeInterval) -> CGFloat {
            let t = duration <= 0 ? 1 : min(max((now - start) / duration, 0), 1)
            let eased = 1 - pow(1 - t, 3)
            return from + (to - from) * eased
        }
        func done(_ now: CFTimeInterval) -> Bool { now - start >= duration }
    }

    private var appear: [String: Fade] = [:]
    private var activeness: [String: Fade] = [:]
    private var leaving: [TextHighlight] = []
    /// Posted from the composer: the fill is already there, only the underline and the active fill come in.
    private var posted: Set<String> = []
    private var timer: Timer?

    private func animate(from old: [TextHighlight]) {
        let now = CACurrentMediaTime()
        // Only changes after the view is on screen fade; a page that opens shows its highlights as they are.
        let animated = window != nil
        let pendingRanges = Set(old.filter(\.pending).map { $0.range.location * 100_000 + $0.range.length })
        for mark in marks where !mark.pending {
            let isNew = !old.contains { $0.id == mark.id }
            let fromPending = isNew && pendingRanges.contains(mark.range.location * 100_000 + mark.range.length)
            if fromPending { posted.insert(mark.id) }
            let target: CGFloat = mark.active ? 1 : 0
            let current = activeness[mark.id]?.value(now) ?? (fromPending ? 0 : target)
            activeness[mark.id] = Fade(from: animated ? current : target, to: target, start: now, duration: 0.2)
            if isNew { appear[mark.id] = Fade(from: animated ? 0 : 1, to: 1, start: now, duration: 0.2) }
        }
        if animated {
            for mark in old where !marks.contains(where: { $0.id == mark.id }) && !mark.pending {
                leaving.append(mark)
                appear[mark.id] = Fade(from: appear[mark.id]?.value(now) ?? 1, to: 0, start: now, duration: 0.15)
            }
        }
        if animated, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        leaving.removeAll { appear[$0.id]?.done(now) ?? true }
        needsDisplay = true
        if appear.values.allSatisfy({ $0.done(now) }) && activeness.values.allSatisfy({ $0.done(now) }) && leaving.isEmpty {
            timer?.invalidate()
            timer = nil
            appear = appear.filter { id, _ in marks.contains { $0.id == id } }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            timer?.invalidate()
            timer = nil
            model?.selectionCleared(in: self)
        }
    }

    /// One rect per line the range covers, in view coordinates, without the spacing under the line.
    func lineRects(_ range: NSRange) -> [NSRect] {
        guard let layout = layoutManager, let container = textContainer, NSMaxRange(range) <= (string as NSString).length else { return [] }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let text = string as NSString
        var pieces: [NSRange] = []
        // Per line, without the space the line wraps at, so a wrapped highlight has no blank tail.
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, _ in
            var chars = layout.characterRange(forGlyphRange: NSIntersectionRange(line, glyphs), actualGlyphRange: nil)
            while chars.length > 0,
                  let scalar = UnicodeScalar(text.character(at: NSMaxRange(chars) - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                chars.length -= 1
            }
            if chars.length > 0 { pieces.append(layout.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)) }
        }
        var rects: [NSRect] = []
        for piece in pieces {
            layout.enumerateEnclosingRects(forGlyphRange: piece, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                var r = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                // Every line but the last carries the line spacing under it.
                if r.height > InlineText.lineHeight + 2 { r.size.height = max(r.height - self.spacing, 1) }
                rects.append(r)
            }
        }
        return rects
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let all = marks + leaving.filter { leaving in !marks.contains { $0.id == leaving.id } }
        guard !all.isEmpty else { return }
        let now = CACurrentMediaTime()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for mark in all {
            let shown = mark.pending ? 1 : appear[mark.id]?.value(now) ?? 1
            let active = mark.pending ? 0 : activeness[mark.id]?.value(now) ?? (mark.active ? 1 : 0)
            guard shown > 0 else { continue }
            for line in lineRects(mark.range) where line.intersects(rect) {
                let path = NSBezierPath(roundedRect: line, xRadius: 2, yRadius: 2)
                let fill = CommentColors.highlight(dark: dark, active: active)
                let fillShown = posted.contains(mark.id) && marks.contains(mark) ? 1 : shown
                fill.withAlphaComponent(fill.alphaComponent * fillShown).setFill()
                path.fill()
                if !mark.pending {
                    NSGraphicsContext.saveGraphicsState()
                    path.addClip()
                    let underline = CommentColors.underline(dark: dark)
                    underline.withAlphaComponent(underline.alphaComponent * shown).setFill()
                    NSRect(x: line.minX, y: line.maxY - 2, width: line.width, height: 2).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for mark in marks where !mark.pending {
            lineRects(mark.range).forEach { addCursorRect($0, cursor: .pointingHand) }
        }
    }

    private func mark(at point: NSPoint) -> String? {
        marks.first { !$0.pending && lineRects($0.range).contains { $0.contains(point) } }?.id
    }

    // MARK: Mouse and selection

    override func mouseDown(with event: NSEvent) {
        model?.pill.hide()
        let point = convert(event.locationInWindow, from: nil)
        // Tracks the drag until the mouse goes up.
        super.mouseDown(with: event)
        if selectedRange().length > 0 {
            finishSelection()
        } else if event.clickCount == 1 {
            if let id = mark(at: point) { model?.pick(id) } else { onClick?() }
        }
    }

    /// What a mouse-up after a selection does; also the path tests drive.
    func finishSelection() {
        model?.selectionEnded(in: self)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if stillSelecting || selectedRange().length == 0 { model?.selectionCleared(in: self) }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // One selection at a time across the page's many text views.
        if resigned, selectedRange().length > 0 { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }

    /// The selection's line rects in view coordinates, after trimming white space at the ends.
    func selectionRects() -> [NSRect] {
        let range = CommentAnchoring.trimmed(selectedRange(), in: string as NSString)
        return range.length > 0 ? lineRects(range) : []
    }

    @objc func addComment(_ sender: Any?) {
        model?.openComposer(from: self)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(addComment(_:)) {
            return model?.meetingID != nil && CommentAnchoring.trimmed(selectedRange(), in: string as NSString).length > 0
        }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var items: [NSMenuItem] = []
        if model?.meetingID != nil, CommentAnchoring.trimmed(selectedRange(), in: string as NSString).length > 0 {
            items.append(NSMenuItem(title: "Add Comment", action: #selector(addComment(_:)), keyEquivalent: ""))
        }
        items += extraMenu?() ?? []
        guard !items.isEmpty else { return menu }
        if menu.numberOfItems > 0 { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

// MARK: Comment button

/// The floating "Comment" button over a selection; one per window, moved to whichever text holds the selection.
final class CommentPillController {
    private(set) weak var owner: CommentTextView?
    var onComment: (() -> Void)?
    let view = CommentPill()
    private var scrollWatch: NSObjectProtocol?

    init() {
        view.onClick = { [weak self] in self?.onComment?() }
    }

    var isShown: Bool { owner != nil && view.superview != nil }

    func show(over text: CommentTextView) {
        owner = text
        guard let container = text.enclosingScrollView ?? text.window?.contentView else { return }
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            if let watch = scrollWatch { NotificationCenter.default.removeObserver(watch) }
            if let clip = (container as? NSScrollView)?.contentView {
                clip.postsBoundsChangedNotifications = true
                scrollWatch = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.place() }
            }
        }
        place()
        view.layer?.removeAllAnimations()
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }
    }

    func hide() {
        owner = nil
        guard view.superview != nil else { return }
        view.removeFromSuperview()
    }

    /// Centred over the selection's first line, 10 pt above it, or under the selection when there is no room above.
    func place() {
        guard let owner, let container = view.superview, let first = owner.selectionRects().first else { return }
        let union = owner.selectionRects().reduce(first) { $0.union($1) }
        let line = container.convert(first, from: owner)
        let whole = container.convert(union, from: owner)
        let size = view.pillSize
        let margin = CommentPill.shadowMargin
        let flipped = container.isFlipped
        let topOfLine = flipped ? line.minY : line.maxY
        let roomAbove = flipped ? topOfLine - container.bounds.minY : container.bounds.maxY - topOfLine
        view.below = roomAbove < size.height + 10 + 4
        var pillRect = NSRect(x: line.midX - size.width / 2, y: 0, width: size.width, height: size.height)
        if view.below {
            let bottom = flipped ? whole.maxY : whole.minY
            pillRect.origin.y = flipped ? bottom + 10 : bottom - 10 - size.height
        } else {
            pillRect.origin.y = flipped ? topOfLine - 10 - size.height : topOfLine + 10
        }
        pillRect.origin.x = min(max(pillRect.minX, container.bounds.minX + 8), container.bounds.maxX - 8 - size.width)
        view.frame = pillRect.insetBy(dx: -margin, dy: -margin)
        view.needsDisplay = true
    }

    /// The button's rect in its container, for tests.
    var pillFrame: NSRect { view.frame.insetBy(dx: CommentPill.shadowMargin, dy: CommentPill.shadowMargin) }
}

final class CommentPill: NSView {
    static let shadowMargin: CGFloat = 16
    var onClick: (() -> Void)?
    /// Under the selection, the caret pointing up.
    var below = false

    private let title = "Comment"
    private var font: NSFont { .systemFont(ofSize: 12, weight: .semibold) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Comment")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var pillSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(10 + 13 + 6 + text.width + 10), height: 28)
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin).contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin).contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin), cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        let path = NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
        // The caret points at the selection.
        let caret = NSBezierPath()
        let down = !below
        let edge = isFlipped == down ? pill.maxY : pill.minY
        let out: CGFloat = isFlipped == down ? 5 : -5
        caret.move(to: NSPoint(x: pill.midX - 5, y: edge))
        caret.line(to: NSPoint(x: pill.midX + 5, y: edge))
        caret.line(to: NSPoint(x: pill.midX, y: edge + out))
        caret.close()
        path.append(caret)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: isFlipped ? 4 : -4)
        shadow.set()
        CommentColors.pill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let ink = CommentColors.onPill
        var x = pill.minX + 10
        if let symbol = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: x + (13 - size.width) / 2, y: pill.midY - size.height / 2, width: size.width, height: size.height))
        }
        x += 13 + 6
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let text = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: x, y: pill.midY - text.height / 2), withAttributes: attributes)
    }
}

// MARK: Composer field

/// The composer's text field: grows with its text from 64 pt, ⌘↩ submits, ⇧⌘↩ submits the other way, Esc cancels,
/// ⌘Z undoes.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder = "Add a comment"
    let submit: () -> Void
    var alternate: (() -> Void)?
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerTextView {
        let view = ComposerTextView.make()
        view.placeholder = placeholder
        view.setAccessibilityPlaceholderValue(placeholder)
        view.delegate = context.coordinator
        view.string = text
        context.coordinator.parent = self
        view.onSubmit = { shift in
            let parent = context.coordinator.parent
            if shift, let alternate = parent.alternate { alternate() } else { parent.submit() }
        }
        view.onCancel = { context.coordinator.parent.cancel() }
        view.onFocus = { focused in
            DispatchQueue.main.async { context.coordinator.parent.focused = focused }
        }
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        return view
    }

    func updateNSView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text { view.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
        return CGSize(width: width, height: nsView.height(for: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }
    }
}

final class ComposerTextView: NSTextView {
    /// True with ⇧ held.
    var onSubmit: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var placeholder = "Add a comment"
    static let inset = NSSize(width: 9, height: 7)

    static func make() -> ComposerTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 64), textContainer: container)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.textContainerInset = inset
        view.font = .systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.5
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.setAccessibilityLabel("Comment")
        view.setAccessibilityPlaceholderValue("Add a comment")
        return view
    }

    func height(for width: CGFloat) -> CGFloat {
        guard let layout = layoutManager, let container = textContainer else { return 64 }
        let previous = container.size
        container.size = NSSize(width: max(width - Self.inset.width * 2, 10), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        container.size = previous
        return max(64, ceil(used + Self.inset.height * 2))
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(
                at: NSPoint(x: Self.inset.width, y: Self.inset.height),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isSubmit(event) {
            onSubmit?(event.modifierFlags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isSubmit(event) { return onSubmit?(event.modifierFlags.contains(.shift)) ?? () }
        super.keyDown(with: event)
    }

    private func isSubmit(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) && (event.keyCode == 36 || event.keyCode == 76)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }
}
