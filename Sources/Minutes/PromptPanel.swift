import AppKit
import SwiftUI

/// Small floating card in the top-right corner, shown over full-screen meetings without taking focus.
/// Several cards stack downwards in the order they came; a card the user dragged away leaves the stack.
final class PromptPanel: NSPanel, NSTextFieldDelegate {
    enum Icon {
        case microphone, transcript, summary, warning

        var symbol: String {
            switch self {
            case .microphone: "mic"
            case .transcript: "text.bubble"
            case .summary: "doc.plaintext"
            case .warning: "exclamationmark"
            }
        }
    }

    /// How the first button, the default one, is drawn: in the accent colour, or red for Record.
    enum Primary { case accent, record }

    static let width: CGFloat = 380
    private static let textWidth: CGFloat = width - 32 - 36 - 12
    /// The × of a closable card: its size, its inset from the corner, and the room the title leaves it.
    static let closeSize: CGFloat = 22
    static let closeInset: CGFloat = 8
    static let closeClearance: CGFloat = 18
    static let margin: CGFloat = 16
    static let gap: CGFloat = 10
    /// How far a card slides down into place as it appears.
    static let slide: CGFloat = 12

    /// Where the cards stack; tests point it off screen.
    static var area: () -> NSRect? = { NSScreen.main?.visibleFrame }
    private(set) static var stack: [PromptPanel] = []

    private var actions: [() -> Void] = []
    private var buttons: [Int: NSButton] = [:]
    private var spinners: [Int: NSProgressIndicator] = [:]
    private var textStack: NSStackView?
    private var accessory: NSView?
    private var dismissTimer: Timer?
    private var timeout: TimeInterval = 0
    private var deadline: Date?
    private var remaining: TimeInterval?
    private var field: NSTextField?
    private var checkbox: NSButton?
    private var detailLabel: NSTextField?
    private var records: NSHostingView<RecordsRow>?
    private var primaryButton: FilledButton?
    private(set) var closeButton: NSButton?
    private var fired = false
    private var dismissing = false
    private var movedByUser = false

    /// Runs when the panel closes itself after `timeout`.
    var onTimeout: (() -> Void)?
    /// Runs whenever the panel closes.
    var onClose: (() -> Void)?
    /// Runs when the user closes a closable card with its × or Esc, before it fades; no option fires.
    var onDismiss: (() -> Void)?
    /// Has a × and closes on Esc; for cards without a dismissing option.
    let closable: Bool
    /// Buttons that act without closing the card, such as Listen.
    var staysOpen = Set<Int>()

    /// Text of the editable field, when the panel was given `fieldValue`.
    var fieldText: String {
        get { field?.stringValue ?? "" }
        set { field?.stringValue = newValue }
    }

    /// The checkbox's state, when the panel was given `checkbox`.
    var isChecked: Bool { checkbox?.state == .on }

    /// The mode picked on the card, when the panel was given `mode`; the default button is named after it.
    private(set) var mode: RecordMode?

    init(
        icon: Icon = .microphone, title: String, message: String, detail: String? = nil, detailLines: Int = 0,
        monospacedDetail: Bool = false,
        fieldValue: String? = nil, mode: RecordMode? = nil, checkbox: String? = nil, buttons: [(String, () -> Void)],
        primary: Primary = .accent, closable: Bool = false, timeout: TimeInterval = 30
    ) {
        self.mode = mode
        self.closable = closable
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 110),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        contentView = background

        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)
        heading.lineBreakMode = .byTruncatingTail
        if closable { heading.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth - Self.closeClearance).isActive = true }
        let body = NSTextField(wrappingLabelWithString: message)
        body.preferredMaxLayoutWidth = Self.textWidth
        var views: [NSView] = [heading, body]
        var detailView: NSView?
        if let detail {
            let oneLine = detailLines == 1 || monospacedDetail
            let small = oneLine
                ? NSTextField(labelWithString: detail)
                : NSTextField(wrappingLabelWithString: detail)
            small.font = monospacedDetail ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
            small.textColor = .secondaryLabelColor
            if oneLine {
                small.lineBreakMode = .byTruncatingTail
                small.toolTip = detail
                small.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth).isActive = true
            } else {
                small.preferredMaxLayoutWidth = Self.textWidth
                small.maximumNumberOfLines = detailLines
                if detailLines > 1 {
                    small.cell?.truncatesLastVisibleLine = true
                    small.toolTip = detail
                }
            }
            detailLabel = small
            detailView = small
        }
        // With a mode, the picker comes first, its icon row under it, and the tell-people line after the title.
        var picker: NSSegmentedControl?
        if let mode {
            let modes = NSSegmentedControl(
                labels: RecordMode.allCases.map(\.name), trackingMode: .selectOne, target: self, action: #selector(pickMode(_:)))
            modes.segmentDistribution = .fillEqually
            modes.selectedSegment = RecordMode.allCases.firstIndex(of: mode) ?? 0
            // The owner found the regular control too small; extra large draws about 32 pt, earlier systems have only large.
            if #available(macOS 26, *) { modes.controlSize = .extraLarge } else { modes.controlSize = .large }
            modes.font = .systemFont(ofSize: 15, weight: .medium)
            modes.setAccessibilityLabel("Mode")
            modes.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
            picker = modes
            let row = NSHostingView(rootView: Self.recordsRow(mode))
            records = row
            views += [modes, row]
        } else if let detailView {
            views.append(detailView)
        }
        if let fieldValue {
            let field = NSTextField(string: fieldValue)
            field.placeholderString = "Meeting title"
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
            self.field = field
            views.append(field)
        }
        if let detailView, mode != nil { views.append(detailView) }
        if let checkbox {
            let box = NSButton(checkboxWithTitle: checkbox, target: nil, action: nil)
            box.font = .systemFont(ofSize: 12)
            self.checkbox = box
            views.append(box)
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        actions = buttons.map(\.1)
        for (index, (label, _)) in buttons.enumerated().reversed() {
            let button: NSButton
            if index == 0 {
                // The card never becomes key, where a default button draws grey; this one keeps its colour.
                let filled = FilledButton(title: label, fill: primary == .record ? .recordFill : .controlAccentColor)
                primaryButton = filled
                button = filled
                button.target = self
                button.action = #selector(pressed(_:))
                button.keyEquivalent = "\r"
            } else {
                button = NSButton(title: label, target: self, action: #selector(pressed(_:)))
                button.bezelStyle = .push
                button.controlSize = .large
            }
            button.tag = index
            self.buttons[index] = button
            row.addView(button, in: .trailing)
        }
        views.append(row)

        let text = NSStackView(views: views)
        textStack = text
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        // Controls sit a little apart from the text above them, and the buttons further still.
        for (index, view) in views.enumerated() where index > 0 && (view === field || view === self.checkbox || view === picker) {
            text.setCustomSpacing(8, after: views[index - 1])
        }
        if let records { text.setCustomSpacing(8, after: records) }
        text.setCustomSpacing(12, after: views[views.count - 2])
        row.setContentHuggingPriority(.required, for: .vertical)

        let tile = IconTile(icon: icon)
        let stack = NSStackView(views: [tile, text])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16),
            text.widthAnchor.constraint(equalToConstant: Self.textWidth),
            row.trailingAnchor.constraint(equalTo: text.trailingAnchor),
        ])
        if closable {
            let close = CloseButton(target: self, action: #selector(closePressed))
            background.addSubview(close)
            NSLayoutConstraint.activate([
                close.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.closeInset),
                close.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.closeInset),
            ])
            closeButton = close
        }

        self.timeout = timeout
        if timeout > 0 { scheduleDismiss(after: timeout) }
        NotificationCenter.default.addObserver(self, selector: #selector(willMove), name: NSWindow.willMoveNotification, object: self)
    }

    override var canBecomeKey: Bool { true }

    /// The × or Esc: closes like the timeout, without any option.
    func dismiss() {
        guard closable, !fired, !dismissing else { return }
        fired = true
        onDismiss?()
        close()
    }

    @objc private func closePressed() { dismiss() }

    override func keyDown(with event: NSEvent) {
        if closable, event.keyCode == 53 { return dismiss() }
        super.keyDown(with: event)
    }

    // Esc from the title field's editor arrives here.
    override func cancelOperation(_ sender: Any?) {
        if closable { dismiss() } else { super.cancelOperation(sender) }
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTimer?.invalidate()
        deadline = Date().addingTimeInterval(seconds)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.onTimeout?()
            self?.close()
        }
    }

    /// Stops the auto-dismiss while `hold` is true; it resumes with the time it had left.
    func holdTimeout(_ hold: Bool) {
        guard timeout > 0, !fired, !dismissing else { return }
        if hold, remaining == nil, let deadline {
            dismissTimer?.invalidate()
            dismissTimer = nil
            remaining = max(5, deadline.timeIntervalSinceNow)
        } else if !hold, let left = remaining {
            remaining = nil
            scheduleDismiss(after: left)
        }
    }

    var isTimeoutHeld: Bool { remaining != nil }

    func button(_ index: Int) -> NSButton? { buttons[index] }

    /// A view under the detail line, such as the briefing's progress; hidden views take no room.
    func addAccessory(_ view: NSView) {
        guard let textStack, textStack.arrangedSubviews.count >= 2 else { return }
        textStack.insertArrangedSubview(view, at: textStack.arrangedSubviews.count - 1)
        textStack.setCustomSpacing(12, after: view)
        view.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        accessory = view
        spaceAccessory()
    }

    private func spaceAccessory() {
        guard let textStack, let accessory, let index = textStack.arrangedSubviews.firstIndex(of: accessory), index > 0 else { return }
        textStack.setCustomSpacing(accessory.isHidden ? 12 : 6, after: textStack.arrangedSubviews[index - 1])
    }

    /// A small spinner in place of the button's image while it works.
    func setSpinner(_ on: Bool, on index: Int) {
        guard let button = buttons[index] else { return }
        if on, spinners[index] == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.widthAnchor.constraint(equalToConstant: 13), spinner.heightAnchor.constraint(equalToConstant: 13),
                spinner.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 11),
                spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            if !Motion.reduceMotion { spinner.startAnimation(nil) }
            spinners[index] = spinner
            button.image = NSImage(size: NSSize(width: 13, height: 13))
            button.imagePosition = .imageLeading
        } else if !on, let spinner = spinners.removeValue(forKey: index) {
            spinner.stopAnimation(nil)
            spinner.removeFromSuperview()
        }
    }

    /// Fits the card to its content after a change, keeping its top edge; returns whether the size changed.
    @discardableResult
    func refit() -> Bool {
        spaceAccessory()
        layoutIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        guard abs(size.height - frame.height) > 0.5 else { return false }
        var next = frame
        next.origin.y += frame.height - size.height
        next.size.height = size.height
        setFrame(next, display: true, animate: false)
        Self.restack()
        return true
    }

    /// Fades in sliding down into its place in the stack; it takes clicks from the first frame.
    func show() {
        layoutIfNeeded()
        setContentSize(contentView?.fittingSize ?? frame.size)
        Self.stack.append(self)
        guard let place = Self.places()[ObjectIdentifier(self)] else {
            orderFrontRegardless()
            return
        }
        let slides = !Motion.reduceMotion
        setFrame(slides ? place.offsetBy(dx: 0, dy: Self.slide) : place, display: false)
        alphaValue = 0
        orderFrontRegardless()
        Motion.run(Motion.appearDuration) { _ in
            self.animator().alphaValue = 1
            if slides { self.animator().setFrame(place, display: true) }
        }
    }

    /// Fades out, then closes; the cards below move up into the gap.
    override func close() {
        dismissTimer?.invalidate()
        guard !dismissing else { return }
        guard isVisible, alphaValue > 0 else { return finishClose() }
        dismissing = true
        ignoresMouseEvents = true
        Self.stack.removeAll { $0 === self }
        // Without motion the others jump, so they wait until this card has gone.
        let jumps = Motion.reduceMotion
        if !jumps { Self.restack() }
        Motion.run(Motion.fadeDuration, { _ in self.animator().alphaValue = 0 }, completion: {
            self.finishClose()
            if jumps { Self.restack() }
        })
    }

    private func finishClose() {
        onClose?()
        onClose = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.willMoveNotification, object: self)
        Self.stack.removeAll { $0 === self }
        super.close()
    }

    @objc private func willMove(_ note: Notification) {
        guard !movedByUser else { return }
        movedByUser = true
        Self.restack()
    }

    /// Top-right corner first, each card below the one before.
    static func places() -> [ObjectIdentifier: NSRect] {
        guard let area = area() else { return [:] }
        var top = area.maxY - margin
        var result: [ObjectIdentifier: NSRect] = [:]
        for card in stack where !card.movedByUser {
            let size = card.frame.size
            result[ObjectIdentifier(card)] = NSRect(x: area.maxX - size.width - margin, y: top - size.height, width: size.width, height: size.height)
            top -= size.height + gap
        }
        return result
    }

    private static func restack() {
        let places = places()
        let moving = stack.filter { card in places[ObjectIdentifier(card)].map { $0 != card.frame } ?? false }
        guard !moving.isEmpty else { return }
        Motion.run(Motion.appearDuration, animated: !Motion.reduceMotion) { _ in
            for card in moving { card.animator().setFrame(places[ObjectIdentifier(card)]!, display: true) }
        }
    }

    // Typing a title must not be cut off by the auto-dismiss.
    func controlTextDidBeginEditing(_ obj: Notification) {
        dismissTimer?.invalidate()
    }

    // Return in the title field means the default button; leaving the field does nothing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        run(0)
        return true
    }

    private static func recordsRow(_ mode: RecordMode) -> RecordsRow {
        RecordsRow(mode: mode, offersAllow: true, width: textWidth, textSize: 13)
    }

    @objc private func pickMode(_ sender: NSSegmentedControl) {
        guard RecordMode.allCases.indices.contains(sender.selectedSegment) else { return }
        select(RecordMode.allCases[sender.selectedSegment])
    }

    /// Changes the card's mode: its icon row, the tell-people line and the default button follow.
    func select(_ new: RecordMode) {
        guard mode != nil else { return }
        mode = new
        dismissTimer?.invalidate()
        records?.rootView = Self.recordsRow(new)
        detailLabel?.stringValue = new.cardDetail
        primaryButton?.setTitle(new.item)
        layoutIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        if size != frame.size { setContentSize(size) }
    }

    @objc private func pressed(_ sender: NSButton) {
        run(sender.tag)
    }

    private func run(_ index: Int) {
        guard !fired, actions.indices.contains(index) else { return }
        if staysOpen.contains(index) { return actions[index]() }
        fired = true
        close()
        actions[index]()
    }
}

/// The rounded square with the card's symbol: dark on light, light on dark; orange for a failure.
private final class IconTile: NSView {
    private let icon: PromptPanel.Icon
    private let image = NSImageView()

    init(icon: PromptPanel.Icon) {
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: icon == .warning ? .bold : .medium)
        image.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill: NSColor, glyph: NSColor
        if icon == .warning {
            fill = dark ? NSColor(srgbRed: 0.85, green: 0.45, blue: 0.08, alpha: 1) : NSColor(srgbRed: 0.70, green: 0.31, blue: 0, alpha: 1)
            glyph = .white
        } else {
            fill = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
            glyph = dark ? NSColor(white: 0.12, alpha: 1) : .white
        }
        layer?.backgroundColor = fill.cgColor
        image.contentTintColor = glyph
    }
}

/// The round × in a closable card's corner: a muted glyph, with a faint disc under the pointer.
private final class CloseButton: NSButton {
    private var hovered = false { didSet { needsDisplay = true } }

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: PromptPanel.closeSize, height: PromptPanel.closeSize))
        self.target = target
        self.action = action
        isBordered = false
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        toolTip = "Close (Esc)"
        setAccessibilityLabel("Close")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PromptPanel.closeSize),
            heightAnchor.constraint(equalToConstant: PromptPanel.closeSize),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The frame is the disc: no bezel insets around it.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A push button filled with one colour whether or not its window is key.
private final class FilledButton: NSButton {
    private let fill: NSColor

    init(title: String, fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        setTitle(title)
    }

    func setTitle(_ title: String) {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        setAccessibilityLabel(title)
        invalidateIntrinsicContentSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + 28, height: 28)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        // macOS 26 draws push buttons as capsules; earlier versions as rounded rectangles.
        if #available(macOS 26, *) { layer.cornerRadius = bounds.height / 2 } else { layer.cornerRadius = 6 }
        layer.cornerCurve = .continuous
        var color = fill
        if isHighlighted { color = color.blended(withFraction: 0.2, of: .black) ?? color }
        effectiveAppearance.performAsCurrentDrawingAppearance { layer.backgroundColor = color.cgColor }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

/// "Calendar event" choice on the Recording card: none, or one of the events on now.
final class EventMenu: NSPopUpButton {
    private let events: [CalendarEvent]
    private let onPick: (CalendarEvent?) -> Void

    init(events: [CalendarEvent], onPick: @escaping (CalendarEvent?) -> Void) {
        self.events = events
        self.onPick = onPick
        super.init(frame: .zero, pullsDown: false)
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        // Through the menu: addItem(withTitle:) drops an earlier item with the same title.
        let titles = ["Not a calendar meeting"]
            + events.map { "\($0.title)  \(time.string(from: $0.start))–\(time.string(from: $0.end))" }
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = index
            menu?.addItem(item)
        }
        target = self
        action = #selector(picked)
        setAccessibilityLabel("Calendar event")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func picked() {
        let index = selectedTag()
        onPick(index > 0 && index <= events.count ? events[index - 1] : nil)
    }
}
