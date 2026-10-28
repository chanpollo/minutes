import AppKit

/// Small floating card in the top-right corner, shown over full-screen meetings without taking focus.
final class PromptPanel: NSPanel, NSTextFieldDelegate {
    private var actions: [() -> Void] = []
    private var dismissTimer: Timer?
    private var field: NSTextField?
    private var fired = false

    /// Runs when the panel closes itself after `timeout`.
    var onTimeout: (() -> Void)?

    /// Text of the editable field, when the panel was given `fieldValue`.
    var fieldText: String { field?.stringValue ?? "" }

    init(title: String, message: String, fieldValue: String? = nil, buttons: [(String, () -> Void)], timeout: TimeInterval = 30) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
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
        let body = NSTextField(wrappingLabelWithString: message)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 308

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        actions = buttons.map(\.1)
        for (index, (label, _)) in buttons.enumerated().reversed() {
            let button = NSButton(title: label, target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            if index == 0 { button.keyEquivalent = "\r" }
            row.addView(button, in: .trailing)
        }

        var views: [NSView] = [heading, body]
        if let fieldValue {
            let field = NSTextField(string: fieldValue)
            field.placeholderString = "Meeting title"
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 308).isActive = true
            self.field = field
            views.append(field)
        }
        views.append(row)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.setContentHuggingPriority(.required, for: .vertical)
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 308),
        ])

        if timeout > 0 {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                self?.onTimeout?()
                self?.close()
            }
        }
    }

    override var canBecomeKey: Bool { true }

    func show() {
        layoutIfNeeded()
        setContentSize(contentView?.fittingSize ?? frame.size)
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 16, y: screen.maxY - frame.height - 16))
        }
        orderFrontRegardless()
    }

    override func close() {
        dismissTimer?.invalidate()
        super.close()
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

    @objc private func pressed(_ sender: NSButton) {
        run(sender.tag)
    }

    private func run(_ index: Int) {
        guard !fired, actions.indices.contains(index) else { return }
        fired = true
        close()
        actions[index]()
    }
}
