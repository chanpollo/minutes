import AppKit
import SwiftUI

/// The bar's menus, the link sheet and the format under the caret, between the bar and the text view.
final class NotesFormatter: ObservableObject {
    enum Menu { case style, list, more }

    struct LinkDraft: Equatable {
        var url: String
        var existing: Bool
    }

    @Published private(set) var state = NotesFormatState()
    @Published var menu: Menu? { didSet { watch() } }
    @Published var link: LinkDraft? { didSet { watch() } }
    @Published var focused = false
    /// The menu row chosen with the arrow keys.
    @Published var highlight: Int?
    weak var view: NotesTextView?
    /// In the window's content view, top-left origin; clicks outside these close a menu or the sheet.
    var openFrame = CGRect.zero
    var barFrame = CGRect.zero
    /// The rows of the open menu, for the arrow keys.
    var rows: [() -> Void] = []
    private var monitors: [Any] = []

    func update(from view: NotesTextView) {
        let next = view.formatState
        guard next != state else { return }
        // Selection changes arrive while SwiftUI may be updating the text view.
        DispatchQueue.main.async { if self.state != next { self.state = next } }
    }

    func setFocused(_ on: Bool) {
        DispatchQueue.main.async { if self.focused != on { self.focused = on } }
    }

    func run(_ action: Selector) {
        menu = nil
        guard let view else { return }
        if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        view.perform(action, with: nil)
    }

    func toggle(_ next: Menu) {
        link = nil
        highlight = nil
        menu = menu == next ? nil : next
    }

    func showLink(url: String, existing: Bool) {
        menu = nil
        link = LinkDraft(url: url, existing: existing)
    }

    func applyLink() {
        guard let draft = link else { return }
        link = nil
        refocus()
        view?.applyLink(draft.url)
    }

    func removeLink() {
        link = nil
        refocus()
        view?.removeLink()
    }

    func cancelLink() {
        link = nil
        refocus()
    }

    @discardableResult
    func closeAll() -> Bool {
        guard menu != nil || link != nil else { return false }
        let hadLink = link != nil
        menu = nil
        link = nil
        if hadLink { refocus() }
        return true
    }

    private func refocus() {
        guard let view, view.window?.firstResponder !== view else { return }
        view.window?.makeFirstResponder(view)
    }

    private func watch() {
        let open = menu != nil || link != nil
        if !open {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            return
        }
        guard monitors.isEmpty else { return }
        if let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self, let window = self.view?.window, event.window === window, let content = window.contentView else {
                self?.closeAll()
                return event
            }
            let local = content.convert(event.locationInWindow, from: nil)
            let point = CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
            if !self.openFrame.contains(point) && !self.barFrame.contains(point) { self.closeAll() }
            return event
        }) { monitors.append(click) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.menu != nil, event.window === self.view?.window else { return event }
            switch event.keyCode {
            case 125, 126:
                guard !self.rows.isEmpty else { return nil }
                let step = event.keyCode == 125 ? 1 : -1
                self.highlight = ((self.highlight ?? (step > 0 ? -1 : self.rows.count)) + step + self.rows.count) % self.rows.count
                return nil
            case 36, 76, 49:
                if let index = self.highlight, index < self.rows.count { self.rows[index]() } else { self.menu = nil }
                return nil
            case 53:
                self.menu = nil
                return nil
            default:
                self.menu = nil
                return event
            }
        }) { monitors.append(keys) }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }
}

// MARK: Bar layout

/// Which buttons fit: Link, Quote, Strike, Underline and Italic move into "…" in that order as the column narrows.
struct FormatBarLayout {
    enum Optional: CaseIterable { case italic, underline, strike, quote, link }

    let shown: Set<Optional>
    let more: Bool
    /// Left edges of the Aa, list and "…" buttons.
    let styleX: CGFloat, listX: CGFloat, moreX: CGFloat

    static let padding: CGFloat = 5, gap: CGFloat = 2, button: CGFloat = 24, wide: CGFloat = 36, separator: CGFloat = 7

    init(width: CGFloat) {
        var shown = Set(Optional.allCases)
        func total() -> CGFloat {
            var widths: [CGFloat] = [Self.wide, Self.separator, Self.button]
            widths += [Optional.italic, .underline, .strike].filter(shown.contains).map { _ in Self.button }
            widths += [Self.separator, Self.wide, Self.button]
            widths += [Optional.quote, .link].filter(shown.contains).map { _ in Self.button }
            widths += [0, Self.button]
            return Self.padding * 2 + widths.reduce(0, +) + Self.gap * CGFloat(widths.count - 1)
        }
        // "…" always holds Insert Picture…
        for item in [Optional.link, .quote, .strike, .underline, .italic] where total() > width {
            shown.remove(item)
        }
        self.shown = shown
        more = true
        styleX = Self.padding
        let inline = CGFloat(1 + [Optional.italic, .underline, .strike].filter(shown.contains).count)
        listX = Self.padding + Self.wide + Self.gap + Self.separator + Self.gap + inline * (Self.button + Self.gap) + Self.separator + Self.gap
        moreX = width - Self.padding - Self.button
    }
}

// MARK: Editor

/// notes.md under a format bar, with Apple Notes' styles and shortcuts; the file stays plain Markdown.
struct NotesEditor: View {
    @ObservedObject var document: NotesDocument
    var placeholder: String?
    @StateObject private var format = NotesFormatter()
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        GeometryReader { proxy in
            let layout = FormatBarLayout(width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                box(layout)
                overlay(layout, width: proxy.size.width)
            }
        }
    }

    private var reduced: Bool { Motion.reduced(systemReduceMotion) }

    private func box(_ layout: FormatBarLayout) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(spacing: 0) {
            FormatBar(format: format, layout: layout, enabled: document.meetingID != nil)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { format.barFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, frame in format.barFrame = frame }
                })
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            NotesTextArea(document: document, format: format, placeholder: placeholder)
        }
        .background(shape.fill(Color.notesPage))
        .clipShape(shape)
        .overlay(shape.strokeBorder(format.focused ? Color.accentColor : Color.primary.opacity(0.15)))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(format.focused ? 0.18 : 0), lineWidth: 3)
                .padding(-3)
        )
        .animation(reduced ? nil : Motion.fade, value: format.focused)
    }

    @ViewBuilder
    private func overlay(_ layout: FormatBarLayout, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let menu = format.menu {
                let items = menuItems(menu, layout)
                let menuWidth: CGFloat = menu == .more ? 220 : 236
                let anchor = menu == .style ? layout.styleX : menu == .list ? layout.listX : layout.moreX
                FormatMenu(items: items, width: menuWidth, highlight: $format.highlight)
                    .onAppear { format.rows = items.map(\.run) }
                    .onChange(of: items.map(\.id)) { format.rows = items.map(\.run) }
                    .background(frameReporter)
                    .offset(x: max(-8, min(anchor, width - menuWidth + 8)), y: 35)
                    .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: -3)))
            }
            if let draft = format.link {
                LinkSheet(format: format, existing: draft.existing)
                    .frame(width: width)
                    .background(frameReporter)
                    .offset(y: 35)
                    .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: -3)))
            }
        }
        .animation(reduced ? nil : .easeOut(duration: 0.12 * Motion.timeScale), value: format.menu)
        .animation(reduced ? nil : .easeOut(duration: 0.12 * Motion.timeScale), value: format.link?.existing)
    }

    private var frameReporter: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { format.openFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, frame in format.openFrame = frame }
        }
    }

    private func menuItems(_ menu: NotesFormatter.Menu, _ layout: FormatBarLayout) -> [FormatMenuItem] {
        let state = format.state
        let run = { (action: Selector) in { format.run(action) } }
        switch menu {
        case .style:
            let plain = state.list == nil && !state.quote
            return [
                FormatMenuItem(id: "title", label: "Title", keys: "⇧⌘T", font: .system(size: 17, weight: .bold),
                               on: plain && state.block == .title, run: run(#selector(NotesTextView.formatTitle(_:)))),
                FormatMenuItem(id: "heading", label: "Heading", keys: "⇧⌘H", font: .system(size: 15, weight: .bold),
                               on: plain && state.block == .heading, run: run(#selector(NotesTextView.formatHeading(_:)))),
                FormatMenuItem(id: "subheading", label: "Subheading", keys: "⇧⌘J", font: .system(size: 13, weight: .semibold),
                               on: plain && state.block == .subheading, run: run(#selector(NotesTextView.formatSubheading(_:)))),
                FormatMenuItem(id: "body", label: "Body", keys: "⇧⌘B", on: plain && state.block == .body,
                               run: run(#selector(NotesTextView.formatBody(_:)))),
                FormatMenuItem(id: "mono", label: "Monospaced", keys: "⇧⌘M", font: .system(size: 12, design: .monospaced),
                               on: plain && state.block == .mono, run: run(#selector(NotesTextView.formatMonospaced(_:)))),
            ]
        case .list:
            return [
                FormatMenuItem(id: "bullet", label: "Bulleted List", keys: "⇧⌘7", symbol: "list.bullet", on: state.list == .bullet,
                               run: run(#selector(NotesTextView.formatBulletedList(_:)))),
                FormatMenuItem(id: "dash", label: "Dashed List", keys: "⇧⌘8", symbol: "list.dash", on: state.list == .dash,
                               run: run(#selector(NotesTextView.formatDashedList(_:)))),
                FormatMenuItem(id: "number", label: "Numbered List", keys: "⇧⌘9", symbol: "list.number", on: state.list == .number,
                               run: run(#selector(NotesTextView.formatNumberedList(_:)))),
            ]
        case .more:
            var items: [FormatMenuItem] = []
            if !layout.shown.contains(.italic) {
                items.append(FormatMenuItem(id: "italic", label: "Italic", keys: "⌘I", symbol: "italic", on: state.italic,
                                            enabled: !state.code, run: run(#selector(NotesTextView.formatItalic(_:)))))
            }
            if !layout.shown.contains(.underline) {
                items.append(FormatMenuItem(id: "underline", label: "Underline", keys: "⌘U", symbol: "underline", on: state.underline,
                                            enabled: !state.code, run: run(#selector(NotesTextView.formatUnderline(_:)))))
            }
            if !layout.shown.contains(.strike) {
                items.append(FormatMenuItem(id: "strike", label: "Strikethrough", keys: "⇧⌘X", symbol: "strikethrough", on: state.strike,
                                            enabled: !state.code, run: run(#selector(NotesTextView.formatStrikethrough(_:)))))
            }
            if !layout.shown.contains(.quote) {
                items.append(FormatMenuItem(id: "quote", label: "Block Quote", keys: "⌘'", symbol: "text.quote", on: state.quote,
                                            run: run(#selector(NotesTextView.formatBlockQuote(_:)))))
            }
            if !layout.shown.contains(.link) {
                items.append(FormatMenuItem(id: "link", label: "Link…", keys: "⌘K", symbol: "link", on: state.link,
                                            run: run(#selector(NotesTextView.formatLink(_:)))))
            }
            items.append(FormatMenuItem(id: "picture", label: "Insert Picture…", keys: "⇧⌘I", symbol: "photo", on: false,
                                        run: run(#selector(NotesTextView.formatInsertPicture(_:)))))
            return items
        }
    }
}

// MARK: Bar

private struct FormatBar: View {
    @ObservedObject var format: NotesFormatter
    let layout: FormatBarLayout
    let enabled: Bool

    var body: some View {
        let state = format.state
        HStack(spacing: FormatBarLayout.gap) {
            BarButton(help: "Paragraph style", label: "Paragraph style", pressed: format.menu == .style, wide: true) {
                format.toggle(.style)
            } content: {
                HStack(spacing: 2) {
                    Text("Aa").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            BarSeparator()
            BarButton(help: "Bold  ⌘B", label: "Bold", pressed: state.bold, dimmed: state.head || state.code) {
                format.run(#selector(NotesTextView.formatBold(_:)))
            } content: {
                Text("B").font(.system(size: 14, weight: .bold))
            }
            if layout.shown.contains(.italic) {
                BarButton(help: "Italic  ⌘I", label: "Italic", pressed: state.italic, dimmed: state.code) {
                    format.run(#selector(NotesTextView.formatItalic(_:)))
                } content: {
                    Text("I").font(.system(size: 15, weight: .medium, design: .serif).italic())
                }
            }
            if layout.shown.contains(.underline) {
                BarButton(help: "Underline  ⌘U", label: "Underline", pressed: state.underline, dimmed: state.code) {
                    format.run(#selector(NotesTextView.formatUnderline(_:)))
                } content: {
                    Text("U").font(.system(size: 14, weight: .medium)).underline()
                }
            }
            if layout.shown.contains(.strike) {
                BarButton(help: "Strikethrough  ⇧⌘X", label: "Strikethrough", pressed: state.strike, dimmed: state.code) {
                    format.run(#selector(NotesTextView.formatStrikethrough(_:)))
                } content: {
                    Text("S").font(.system(size: 14, weight: .medium)).strikethrough()
                }
            }
            BarSeparator()
            BarButton(help: "List", label: "List", pressed: format.menu == .list, wide: true) {
                format.toggle(.list)
            } content: {
                HStack(spacing: 2) {
                    Image(systemName: "list.bullet").font(.system(size: 13))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            BarButton(help: "Checklist  ⇧⌘L", label: "Checklist", pressed: state.list == .check) {
                format.run(#selector(NotesTextView.formatChecklist(_:)))
            } content: {
                Image(systemName: "checklist").font(.system(size: 13))
            }
            if layout.shown.contains(.quote) {
                BarButton(help: "Block Quote  ⌘'", label: "Block Quote", pressed: state.quote) {
                    format.run(#selector(NotesTextView.formatBlockQuote(_:)))
                } content: {
                    Image(systemName: "text.quote").font(.system(size: 13))
                }
            }
            if layout.shown.contains(.link) {
                BarButton(help: "Link  ⌘K", label: "Link", pressed: state.link) {
                    format.run(#selector(NotesTextView.formatLink(_:)))
                } content: {
                    Image(systemName: "link").font(.system(size: 13))
                }
            }
            if layout.more {
                Spacer(minLength: 0)
                BarButton(help: "More", label: "More", pressed: format.menu == .more) {
                    format.toggle(.more)
                } content: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, FormatBarLayout.padding)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Format")
    }
}

private struct BarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}

/// A 24 pt bar button: grey fill when pressed, no accent; dimmed where it does nothing.
private struct BarButton<Content: View>: View {
    let help: String
    let label: String
    var pressed = false
    var dimmed = false
    var wide = false
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(pressed || hovered && !dimmed ? Color.primary : Color(nsColor: NotesLook.text2))
                .frame(width: wide ? FormatBarLayout.wide : FormatBarLayout.button, height: 24)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(pressed ? Color(nsColor: Self.press) : hovered && !dimmed ? Color(nsColor: Self.hover) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .opacity(dimmed || !enabled ? 0.35 : 1)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(pressed ? .isSelected : [])
    }

    static var press: NSColor { NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white.withAlphaComponent(0.16) : .black.withAlphaComponent(0.09) } }
    static var hover: NSColor { NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white.withAlphaComponent(0.08) : .black.withAlphaComponent(0.05) } }
}

// MARK: Menus

struct FormatMenuItem: Identifiable {
    let id: String
    let label: String
    let keys: String
    var font: Font?
    var symbol: String?
    let on: Bool
    var enabled = true
    let run: () -> Void
}

private struct FormatMenu: View {
    let items: [FormatMenuItem]
    let width: CGFloat
    @Binding var highlight: Int?

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                FormatMenuRow(item: item, highlighted: highlight == index) { highlight = $0 ? index : nil }
            }
        }
        .padding(5)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: NotesLook.menu)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 15, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct FormatMenuRow: View {
    let item: FormatMenuItem
    let highlighted: Bool
    let hover: (Bool) -> Void

    var body: some View {
        Button(action: item.run) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(item.on ? 1 : 0)
                    .frame(width: 14)
                HStack(spacing: 7) {
                    if let symbol = item.symbol {
                        Image(systemName: symbol).font(.system(size: 12)).frame(width: 15)
                    }
                    Text(item.label).font(item.font ?? .system(size: 13))
                }
                Spacer(minLength: 18)
                Text(item.keys)
                    .font(.system(size: 12))
                    .tracking(0.5)
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color(nsColor: .secondaryLabelColor))
            }
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(highlighted ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.4)
        .onHover(perform: hover)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.on ? "selected" : "")
    }
}

/// ⌘K: the link's address under the bar, with Cancel and Add, or Remove and Save for a link already there.
private struct LinkSheet: View {
    @ObservedObject var format: NotesFormatter
    let existing: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: NotesLook.text2))
            TextField("Link", text: Binding(get: { format.link?.url ?? "" }, set: { format.link?.url = $0 }))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit { format.applyLink() }
                .onExitCommand { format.cancelLink() }
            HStack(spacing: 8) {
                if existing {
                    Button("Remove") { format.removeLink() }
                }
                Spacer(minLength: 0)
                Button("Cancel") { format.cancelLink() }
                Button(existing ? "Save" : "Add") { format.applyLink() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: NotesLook.menu)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 15, y: 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link")
    }
}

// MARK: Text

/// The text view inside a scroll view; loads notes.md when it changes underneath and writes every edit back.
struct NotesTextArea: NSViewRepresentable {
    @ObservedObject var document: NotesDocument
    let format: NotesFormatter
    var placeholder: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = NotesTextView.make()
        view.delegate = context.coordinator
        view.formatter = format
        format.view = view
        context.coordinator.view = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NotesTextView else { return }
        let coordinator = context.coordinator
        coordinator.document = document
        view.isEditable = document.meetingID != nil
        view.placeholder = placeholder
        view.onPlay = { [weak document] in document?.play($0) }
        view.onOpen = { [weak document] in document?.open($0) }
        view.onError = { [weak document] in document?.onError?($0) }
        document.insertPicture = { [weak view] in view?.insertPicture($0) ?? false }
        let folder = document.meetingID.flatMap(document.folder)
        let changed = document.revision != coordinator.revision || folder != coordinator.folder
            || document.canPlay != coordinator.canPlay || document.meetingID != coordinator.meetingID
        guard changed else { return }
        let same = document.meetingID == coordinator.meetingID
        let appended = same && document.fresh != nil
        coordinator.revision = document.revision
        coordinator.render(document.text, folder: folder, canPlay: document.canPlay, meetingID: document.meetingID, keepSelection: same)
        if let layout = view.layoutManager, let container = view.textContainer {
            // All of it only when the end has to be scrolled to.
            if appended {
                layout.ensureLayout(for: container)
            } else {
                layout.ensureLayout(forBoundingRect: scroll.documentVisibleRect, in: container)
            }
            view.sizeToFit()
        }
        if appended {
            if let fresh = document.fresh { view.reveal(fresh) }
            // After this pass, once the scroll view has taken the new height.
            DispatchQueue.main.async { [weak view] in view?.scrollToEndOfDocument(nil) }
        }
        document.fresh = nil
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.document?.flush()
        coordinator.document?.insertPicture = nil
        coordinator.undo.removeAllActions()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var view: NotesTextView?
        weak var document: NotesDocument?
        /// The document revision on show.
        var revision = -1
        /// The notes' own undo steps, apart from the window's, so they go with the editor and the meeting.
        let undo = UndoManager()
        var folder: URL?
        var canPlay = false
        var meetingID: String?

        func render(_ text: String, folder: URL?, canPlay: Bool, meetingID: String?, keepSelection: Bool) {
            guard let view, let storage = view.textStorage else { return }
            let selection = view.selectedRange()
            view.folder = folder
            view.canPlay = canPlay
            view.load(text)
            self.folder = folder
            self.canPlay = canPlay
            self.meetingID = meetingID
            if keepSelection {
                view.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
            } else {
                view.caretPlaced = false
                view.setSelectedRange(NSRange(location: 0, length: 0))
                undo.removeAllActions()
                view.scroll(.zero)
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        // Making the Markdown takes longer the longer the notes are, so it waits until it is needed.
        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            document?.edit { [weak view] in view?.markdown }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view else { return }
            view.refreshTyping()
            view.formatter?.update(from: view)
        }
    }
}
