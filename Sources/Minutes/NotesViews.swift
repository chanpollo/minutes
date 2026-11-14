import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct NotesRootView: View {
    @ObservedObject var store: NotesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if store.meetings.isEmpty && store.liveItems.isEmpty {
                EmptyWorkspaceView()
            } else {
                HStack(spacing: 0) {
                    Sidebar(store: store)
                        .frame(width: 260)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            WindowTitle()
            // A note's page is the notes themselves; it has no column to hide.
            if store.page?.item.isNote != true {
                ToolbarItem(placement: .primaryAction) {
                    AsideButton(store: store)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                RecordButton(store: store)
            }
        }
    }

    // Stacked so the page going out and the one coming in crossfade in the same place.
    private var detail: some View {
        ZStack {
            if let page = store.page {
                MeetingPageView(store: store, page: page)
                    .id(page.item.id)
                    .overlay {
                        if let look = store.look {
                            PictureViewer(look: look, play: { _ in store.play(look) }, close: store.closePicture)
                                .transition(Motion.reduced(reduceMotion) ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                    .transition(.opacity)
            } else {
                ContentUnavailableView("No Meeting Selected", systemImage: "doc.text")
                    .background(Color.notesPage)
                    .transition(.opacity)
            }
        }
    }
}

/// The title in the middle of the toolbar, as plain text rather than an item on glass.
private struct WindowTitle: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            item.sharedBackgroundVisibility(.hidden)
        } else {
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("Minutes")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Hides or shows the Comments | Notes column; pressed while it shows, off on pages without one.
private struct AsideButton: View {
    @ObservedObject var store: NotesStore

    var body: some View {
        let label = store.asideHidden ? "Show Notes" : "Hide Notes"
        Toggle(isOn: Binding(get: { !store.asideHidden && store.hasAside }, set: { _ in store.toggleAside() })) {
            Label(label, systemImage: "sidebar.right")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .disabled(!store.hasAside)
        .help("\(label) (⌥⌘0)")
        .accessibilityLabel(label)
    }
}

/// Record, in the default mode, with Record Screen and Record Voice under its arrow; Stop while recording.
private struct RecordButton: View {
    @ObservedObject var store: NotesStore
    @AppStorage(Settings.recordModeKey) private var mode = RecordMode.screen

    var body: some View {
        if store.isRecording {
            Button(action: store.record) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.recording).frame(width: 8, height: 8)
                    Text("Stop")
                }
                .padding(.horizontal, 4)
            }
            .help("Stop recording")
            .accessibilityLabel("Stop recording")
        } else {
            let shortcut = Settings.recordShortcut
            // A button and a chevron menu side by side, so the dot is drawn by SwiftUI and not dimmed as a menu label.
            ControlGroup {
                Button(action: { store.record() }) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.recording).frame(width: 8, height: 8)
                        Text(mode.item)
                    }
                    .padding(.horizontal, 4)
                }
                .help("\(mode.item) (\(shortcut.display))")
                .accessibilityLabel(mode.item)
                Menu {
                    ForEach(RecordMode.allCases, id: \.self) { item in
                        if item == mode, let key = shortcut.menuKeyEquivalent.first {
                            Button(item.item) { store.record(item) }
                                .keyboardShortcut(KeyEquivalent(key), modifiers: EventModifiers(shortcut.modifiers))
                        } else {
                            Button(item.item) { store.record(item) }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuIndicator(.hidden)
                .help("Record Screen or Record Voice")
                .accessibilityLabel("Record options")
            }
        }
    }
}

private extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
    }
}

private struct EmptyWorkspaceView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("No meetings yet")
                .font(.title2.weight(.semibold))
            Text("Meetings you record appear here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.notesPage)
    }
}

// MARK: Page

private struct MeetingPageView: View {
    @ObservedObject var store: NotesStore
    let page: MeetingPage
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The Comments | Notes column's width, 260–420 pt.
    @AppStorage("notesAsideWidth") private var asideWidth = Double(AsideWidth.standard)
    @State private var pageWidth: CGFloat = 0

    var body: some View {
        let state = store.state(of: page)
        let reduced = Motion.reduced(systemReduceMotion)
        let aside: CGFloat = store.asideHidden || !store.hasAside ? 0 : AsideWidth.clamp(CGFloat(asideWidth)) + 1
        let inset = PageMetrics.inset(column: pageWidth - aside)
        VStack(spacing: 0) {
            PageHeader(store: store, page: page, state: state, inset: inset)
            // A note's editor is a bordered box of its own, so no rule above it (the board draws none).
            if !MeetingFormat.isNotePage(page, state: state) { Divider() }
            // Recording, transcribing and done crossfade into each other.
            HStack(spacing: 0) {
                ZStack {
                    switch state {
                    case .recording(let live, let levels):
                        RecordingState(live: live, levels: levels, smooth: !reduced, stop: { store.onStop?() })
                            .transition(.opacity)
                    case .transcribing(let progress):
                        TranscribingState(player: store.player, progress: progress, playable: page.media != .none)
                            .transition(.opacity)
                    case .waiting:
                        TranscribingState(player: store.player, progress: nil, playable: page.media != .none, waiting: true)
                            .transition(.opacity)
                    case .done where page.item.isNote:
                        NotePage(document: store.notes, inset: inset)
                            .transition(.opacity)
                    case .done:
                        HStack(spacing: 0) {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    ZStack(alignment: .topLeading) {
                                        switch store.tab {
                                        case .summary:
                                            SummaryTab(store: store, page: page)
                                                .transition(.opacity)
                                        case .transcript:
                                            TranscriptTab(player: store.player, comments: store.comments, transcript: page.transcript) {
                                                store.player.seek(to: $0, play: true)
                                            } rename: { [id = page.item.id] in
                                                // The meeting the menu was opened on; another can be selected while the name is asked.
                                                store.renameSpeaker($0, to: $1, in: id)
                                            }
                                            .transition(.opacity)
                                        }
                                    }
                                    .padding(.horizontal, inset)
                                    .padding(.top, 24)
                                    .padding(.bottom, 32)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .modifier(CommentTextScroller(model: store.comments, proxy: proxy))
                            }
                            if !store.asideHidden {
                                let width = AsideWidth.clamp(CGFloat(asideWidth))
                                Aside(comments: store.comments, notes: store.notes, tab: store.tab, width: width) {
                                    asideWidth = Double(AsideWidth.clamp($0))
                                }
                                .transition(Motion.reduced(reduced) ? .opacity : ColumnReveal.transition(width: width + 1))
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .animation(Motion.appear, value: state.kind)
                // Notes can be taken while the meeting is recorded or transcribed; comments wait for the text.
                if state.kind != .done, store.hasAside, !store.asideHidden {
                    let width = AsideWidth.clamp(CGFloat(asideWidth))
                    Aside(comments: nil, notes: store.notes, tab: store.tab, width: width) {
                        asideWidth = Double(AsideWidth.clamp($0))
                    }
                    .transition(Motion.reduced(reduced) ? .opacity : ColumnReveal.transition(width: width + 1))
                }
            }
            if page.media != .none {
                let video: Bool = { if case .video = page.media { return true } else { return false } }()
                PlayerArea(player: store.player, always: state.kind == .done, capture: state.kind == .done && video ? store.capture : nil)
            }
        }
        .background(Color.notesPage)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { pageWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in pageWidth = width }
        })
    }
}

enum PageMetrics {
    /// The page's left and right margin; the header's title lines up with the text under it. A page column under
    /// 520 pt, as at the smallest window with the notes column shown, keeps the narrower margin.
    static func inset(column: CGFloat) -> CGFloat {
        column > 0 && column < 520 ? 28 : 40
    }
}

/// The Comments | Notes column, resized by dragging its left edge.
private struct Aside: View {
    /// nil while the meeting is recorded or transcribed: only its notes.
    let comments: CommentsModel?
    let notes: NotesDocument
    let tab: NotesStore.Tab
    let width: CGFloat
    let resize: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Divider()
            if let comments {
                SideColumn(comments: comments, notes: notes, tab: tab)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Notes")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                        .accessibilityAddTraits(.isHeader)
                    NotesAside(document: notes)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.notesAside)
            }
        }
        .frame(width: width + 1)
        .overlay(alignment: .leading) {
            // Over the divider and a few points into the column, which clips anything further out.
            ColumnEdge(width: width, resize: resize)
                .frame(width: 6)
        }
    }
}

enum AsideWidth {
    static let standard: CGFloat = 300
    static let range: ClosedRange<CGFloat> = 260...420

    static func clamp(_ width: CGFloat) -> CGFloat {
        width.isFinite ? min(max(width, range.lowerBound), range.upperBound) : standard
    }
}

/// The column slides in and out at the window's right edge while the page narrows or widens beside it.
private struct ColumnReveal: ViewModifier, Animatable {
    let width: CGFloat
    var shown: CGFloat
    /// A view on its way out keeps its last place, so it is moved along with the page's growing edge.
    var leaving = false

    static func transition(width: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ColumnReveal(width: width, shown: 0), identity: ColumnReveal(width: width, shown: 1)),
            removal: .modifier(active: ColumnReveal(width: width, shown: 0, leaving: true),
                               identity: ColumnReveal(width: width, shown: 1, leaving: true)))
    }

    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: width, alignment: .leading)
            .frame(width: width * min(max(shown, 0), 1), alignment: .leading)
            .clipped()
            .offset(x: leaving ? width * (1 - min(max(shown, 0), 1)) : 0)
    }
}

/// The draggable left edge of the column; the cursor shows which ways it can still go.
private struct ColumnEdge: NSViewRepresentable {
    let width: CGFloat
    let resize: (CGFloat) -> Void

    func makeNSView(context: Context) -> ColumnEdgeView {
        let view = ColumnEdgeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ColumnEdgeView, context: Context) {
        view.resize = resize
        if view.width != width {
            view.width = width
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

final class ColumnEdgeView: NSView {
    var width = AsideWidth.standard
    var resize: (CGFloat) -> Void = { _ in }
    private var start: (x: CGFloat, width: CGFloat)?

    override func resetCursorRects() {
        let cursor: NSCursor = width <= AsideWidth.range.lowerBound ? .resizeLeft
            : width >= AsideWidth.range.upperBound ? .resizeRight : .resizeLeftRight
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        start = (event.locationInWindow.x, width)
    }

    // Dragging left widens the column.
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        resize(start.width + start.x - event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { "Notes column width" }
    override func accessibilityValue() -> Any? { Int(width) }

    override func accessibilityPerformIncrement() -> Bool {
        resize(width + 20)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        resize(width - 20)
        return true
    }
}

extension NotesStore.PageState {
    enum Kind { case recording, transcribing, waiting, done }

    var kind: Kind {
        switch self {
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .waiting: return .waiting
        case .done: return .done
        }
    }
}

private struct PageHeader: View {
    @ObservedObject var store: NotesStore
    let page: MeetingPage
    let state: NotesStore.PageState
    var inset: CGFloat = PageMetrics.inset(column: 0)

    var body: some View {
        let meta = page.item.meta
        let done: Bool = { if case .done = state { return true } else { return false } }()
        // A note: the title, its line and the buttons; no people, video, tabs or confidential switch.
        let note = MeetingFormat.isNotePage(page, state: state)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // Transcriber holds the folder path while it runs; a rename would move the folder away from it.
                    if done {
                        TitleField(title: meta.title, fresh: store.freshNote == page.item.id) { store.rename(page.item.id, to: $0) }
                    } else {
                        Text(meta.title)
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(1)
                            .help("The title can be changed once the transcript is ready")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if page.item.isArchived {
                            ArchivedTag()
                        }
                        let (line, tail) = MeetingFormat.pageLine(page, state: state)
                        let app = tail.map { " · " + $0 }.flatMap { line.hasSuffix($0) ? $0 : nil }
                        // When it does not fit, the app goes to a line of its own rather than the line breaking anywhere.
                        ViewThatFits(in: .horizontal) {
                            Text(line).fixedSize()
                            if let app {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.dropLast(app.count)).fixedSize()
                                    Text(app.dropFirst(3))
                                }
                            }
                            Text(line).lineLimit(2).truncationMode(.tail)
                        }
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Menu {
                        GroupChoices(store: store, item: page.item)
                    } label: {
                        Label(store.groupName(store.groupID(of: page.item)) ?? "No group", systemImage: "folder")
                    }
                    .fixedSize()
                    .help("Group")
                    .accessibilityLabel("Group: \(store.groupName(store.groupID(of: page.item)) ?? "No group")")
                    // A live recording shows its staging folder.
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([page.item.folder]) }
                        .disabled(!FileManager.default.fileExists(atPath: page.item.folder.path))
                    Button("Export") { export(page.item) }
                        .disabled(!done)
                }
                .fixedSize()
            }
            if !note {
                People(store: store, id: page.item.id, meta: meta, live: page.staged, canChange: done)
            }
            if !note, done || page.media != .none {
                MediaNote(meta: meta, player: store.player, video: { if case .video = page.media { return true } else { return false } }(),
                          captures: store.captures)
            }
            if done, !note {
                HStack(spacing: 12) {
                    Picker("View", selection: $store.tab.animation(Motion.fade)) {
                        ForEach(NotesStore.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 12)
                    Toggle("Don't send for summary (confidential)", isOn: Binding(
                        get: { meta.confidential ?? false },
                        set: { store.setConfidential($0, for: page.item.id) }))
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, inset)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private func export(_ item: MeetingItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.folder.lastPathComponent + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { store.export(item.id, to: url) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

/// Me and the calendar's invitees as chips.
private struct People: View {
    @ObservedObject var store: NotesStore
    let id: String
    let meta: MeetingMeta
    let live: Bool
    let canChange: Bool
    // Every event on when the meeting began; two or more means it may have been named after the wrong one.
    @State private var events: [CalendarEvent] = []

    var body: some View {
        let people = ["Me"] + (meta.attendees ?? [])
        let source = meta.attendees != nil ? "from Calendar" : live ? "No calendar event at this time" : nil
        FlowLayout(spacing: 6) {
            ForEach(Array(people.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            if let source {
                Text(source)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
            }
            if canChange, events.count > 1 {
                Menu {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        Button {
                            store.useEvent(event, for: id)
                        } label: {
                            if event.title == meta.title {
                                Label(Self.label(event), systemImage: "checkmark")
                            } else {
                                Text(Self.label(event))
                            }
                        }
                        .disabled(event.title == meta.title)
                    }
                } label: {
                    Text("Other meetings at this time")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(height: 22)
                .help("Name this meeting after another event on your calendar, with its invitees")
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: "\(meta.startedAt.timeIntervalSince1970)\(canChange)") {
            events = canChange ? CalendarTitle.on(appBundleID: meta.bundleID, voice: meta.recordMode == .voice, at: meta.startedAt) : []
        }
    }

    private static func label(_ event: CalendarEvent) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        return "\(event.title) · \(time.string(from: event.start))–\(time.string(from: event.end))"
    }
}

/// The video, collapsible, or one quiet line when retention deleted it.
private struct MediaNote: View {
    let meta: MeetingMeta
    @ObservedObject var player: MediaPlayer
    let video: Bool
    let captures: Int
    @AppStorage("notesVideoCollapsed") private var collapsed = false
    @State private var flash = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let deleted = deletedLine
        if video {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Motion.animate(Motion.reduced(reduceMotion) ? nil : Motion.appear) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text("Video")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed ? "Show Video" : "Hide Video")
                if !collapsed {
                    VideoView(player: player.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxHeight: 240)
                        .overlay {
                            if let poster = player.poster, player.time < player.videoStart {
                                Image(decorative: poster, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(Color.white.opacity(flash).allowsHitTesting(false))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                }
            }
            .onChange(of: captures) {
                // Capture: a quick white flash over the picture, like a shutter.
                guard !Motion.reduced(reduceMotion) else { return }
                flash = 0.85
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.25 * Motion.timeScale)) { flash = 0 } }
            }
        } else if let deleted {
            Text(deleted)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var deletedLine: String? {
        let start = meta.endedAt ?? meta.startedAt
        let days = { (date: Date) -> String in
            let n = max(0, Calendar.current.dateComponents([.day], from: start, to: date).day ?? 0)
            return n == 1 ? "1 day" : "\(n) days"
        }
        switch (meta.videoDeletedAt, meta.audioDeletedAt) {
        case let (video?, audio?):
            return "Video deleted after \(days(video)), audio tracks after \(days(audio))"
        case let (video?, nil):
            return "Video deleted after \(days(video))"
        case let (nil, audio?):
            return "Audio tracks deleted after \(days(audio))"
        case (nil, nil):
            return nil
        }
    }
}

private struct TitleField: View {
    let title: String
    /// A note just made: the field starts empty with the caret in it, so typing names the note.
    var fresh = false
    let commit: (String) -> Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Untitled", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .bold))
            .accessibilityLabel("Title")
            .focused($focused)
            .onAppear {
                draft = fresh ? "" : title
                if fresh { DispatchQueue.main.async { focused = true } }
            }
            .onChange(of: title) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onSubmit(save)
            // Switching meetings removes the field before it reports losing focus.
            .onDisappear(perform: save)
            .onExitCommand {
                draft = title
                focused = false
            }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else {
            draft = title
            return
        }
        if !commit(trimmed) { draft = title }
    }
}

/// Lays chips out in rows, wrapping to the next row when one does not fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.last.map { $0.frame.maxX } ?? 0 }.max() ?? 0
        return CGSize(width: width, height: rows.last?.last?.frame.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, frame) in row {
                subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                      proposal: ProposedViewSize(frame.size))
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [[(index: Int, frame: CGRect)]] {
        var rows: [[(index: Int, frame: CGRect)]] = [[]]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rows[rows.count - 1].append((index, CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return rows
    }
}

// MARK: Live states

private struct RecordingState: View {
    let live: LiveMeeting
    let levels: () -> (me: Float, others: Float)
    let smooth: Bool
    let stop: () -> Void
    @ObservedObject private var mute = MicMute.shared

    var body: some View {
        let names = live.mode.meters
        VStack(spacing: 14) {
            TimelineView(.periodic(from: live.startedAt, by: 1)) { context in
                HStack(spacing: 8) {
                    Circle().fill(Color.recording).frame(width: 10, height: 10)
                    Text("Recording · " + AppDelegate.clock(context.date.timeIntervalSince(live.startedAt)))
                        .monospacedDigit()
                }
                .font(.system(size: 17, weight: .semibold))
            }
            HStack(spacing: 12) {
                ModeChip(mode: live.mode)
                RecordsRow(mode: live.mode)
            }
            Text(Self.message(live))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            LevelMeters(levels: levels, names: (mute.on ? "\(names.me) (muted)" : names.me, names.others), smooth: smooth)
                .frame(width: 320)
                .padding(.vertical, 8)
            HStack(spacing: 12) {
                Button(mute.on ? "Unmute Microphone" : "Mute Microphone", action: mute.toggle)
                    .help("The microphone track records silence while muted")
                Button("Stop recording", action: stop)
                    .buttonStyle(StopButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A Screen recording of an app ends with the call; Voice, or no app, the user stops.
    static func message(_ live: LiveMeeting) -> String {
        if let app = live.app, live.mode == .screen {
            return "\(app) is using the microphone. The transcript appears here when the call ends."
        }
        return "The transcript appears here when the recording stops."
    }
}

/// The recording's mode, in a neutral pill.
private struct ModeChip: View {
    let mode: RecordMode

    var body: some View {
        Text(mode.name)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .accessibilityLabel("Mode: \(mode.name)")
    }
}

private struct LevelMeters: View {
    let levels: () -> (me: Float, others: Float)
    let names: (me: String, others: String)
    let smooth: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let now = levels()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                meter(names.me, now.me)
                meter(names.others, now.others)
            }
        }
    }

    private func meter(_ label: String, _ value: Float) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .leading)
            Bar(value: Double(value), fill: .primary, animation: smooth ? Motion.meter : nil)
                .accessibilityElement()
            .accessibilityLabel("\(label) level")
            .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) percent")
        }
    }
}

/// A 6 pt track filled to `value` (0…1), for the level meters and transcription progress.
private struct Bar: View {
    let value: Double
    let fill: Color
    /// How the fill follows a new value.
    var animation: Animation?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(fill)
                    .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
                    .animation(animation, value: value)
            }
        }
        .frame(height: 6)
    }
}

/// Red in every window state; a prominent button turns grey when the window is not key.
private struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.recordFill.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
    }
}

private struct TranscribingState: View {
    @ObservedObject var player: MediaPlayer
    let progress: Double?
    let playable: Bool
    /// Behind another meeting in the transcriber: no bar, as nothing moves yet.
    var waiting = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        VStack(spacing: 12) {
            Text(waiting ? "Waiting to transcribe" : progress.map { "Transcribing · \(Int($0 * 100))%" } ?? "Transcribing")
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
            if waiting {
                Text("It starts when the meeting before it is done.")
                    .foregroundStyle(.secondary)
            } else if let progress {
                Bar(value: progress, fill: .accentColor, animation: Motion.reduced(systemReduceMotion) ? nil : Motion.appear)
                    .frame(width: 320)
                    .accessibilityElement()
                    .accessibilityLabel("Transcription progress")
                    .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
            } else {
                ProgressView().progressViewStyle(.linear)
                    .frame(width: 320)
                    .accessibilityLabel("Transcription progress")
            }
            if playable {
                Text("The audio is saved. You can play it while the transcript is being written.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button(player.isPlaying ? "Pause" : "Play recording", action: player.toggle)
                    .disabled(player.player == nil)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Player

/// The bar under the page: always on a finished meeting, on the transcribing page once playback started.
private struct PlayerArea: View {
    @ObservedObject var player: MediaPlayer
    let always: Bool
    var capture: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = always || player.isPlaying || player.time > 0
        VStack(spacing: 0) {
            if shown {
                Divider()
                PlayerBar(player: player, capture: capture)
            }
        }
        .animation(Motion.reduced(reduceMotion) ? nil : Motion.appear, value: shown)
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: MediaPlayer
    var capture: (() -> Void)?
    @ObservedObject private var briefing = BriefingCenter.shared
    private static let speeds: [Float] = [1, 1.25, 1.5, 2]

    var body: some View {
        let ready = player.player != nil
        let blocked = briefing.recording && !player.isPlaying
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.notesPage)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.primary.opacity(ready && !blocked ? 1 : 0.4)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!ready || blocked)
            .help(blocked ? "Not while recording" : player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Text(MeetingFormat.clock(player.time))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
            Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                .controlSize(.small)
                .disabled(!ready)
                .accessibilityLabel("Position")
                .accessibilityValue("\(MeetingFormat.clock(player.time)) of \(MeetingFormat.clock(player.duration))")
            Text(MeetingFormat.clock(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)
            if let capture {
                Button(action: capture) {
                    Label("Capture", systemImage: "camera")
                }
                .disabled(!ready)
                .help("Add this frame to Notes")
            }
            Menu {
                ForEach(Self.speeds, id: \.self) { speed in
                    Toggle(Self.label(speed), isOn: Binding(get: { player.speed == speed }, set: { _ in player.setSpeed(speed) }))
                }
            } label: {
                Text(Self.label(player.speed)).monospacedDigit()
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")
            .accessibilityLabel("Playback speed \(Self.label(player.speed))")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.notesChrome)
    }

    private static func label(_ speed: Float) -> String {
        (speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", speed)) + "×"
    }
}

private struct VideoView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // The bar under the page drives playback.
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: Notes

/// A note's page under its header: the notes editor fills the column, with the aside's quiet line under it.
private struct NotePage: View {
    @ObservedObject var document: NotesDocument
    let inset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotesEditor(document: document, placeholder: "Start writing")
            Text("Saved to notes.md · Record Screen or Record Voice while this note is open adds the recording to it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, inset)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotesAside: View {
    @ObservedObject var document: NotesDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotesEditor(document: document)
            // Kept in the layout so the editor does not jump when the first save lands.
            Text("Saved to notes.md")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .opacity(document.onDisk ? 1 : 0)
                .accessibilityHidden(!document.onDisk)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: App icons

/// The meeting app's own icon, or nil when the app is unknown, not installed or only hosted the meeting.
enum AppIcons {
    private static var cache: [String: (image: NSImage, name: String)?] = [:]

    static func image(bundleID: String?, app: String?) -> NSImage? {
        hosted(bundleID: bundleID, app: app) ? nil : installed(bundleID: bundleID, app: app)?.image
    }

    /// True when the stored app is not the app that held the mic, e.g. Google Meet in Chrome: that icon would
    /// name the wrong app.
    static func hosted(bundleID: String?, app: String?) -> Bool {
        guard let bundleID, let app else { return false }
        let owner = MeetingApps.owner(of: bundleID)
        guard let name = MeetingApps.known[owner] ?? installed(bundleID: bundleID, app: app)?.name else { return false }
        return !(name.hasPrefix(app) || app.hasPrefix(name))
    }

    private static func installed(bundleID: String?, app: String?) -> (image: NSImage, name: String)? {
        let id = bundleID ?? app.flatMap { name in MeetingApps.known.first { $0.value == name }?.key }
        guard let id else { return nil }
        if let cached = cache[id] { return cached }
        let entry = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MeetingApps.owner(of: id)).map { url in
            (NSWorkspace.shared.icon(forFile: url.path), url.deletingPathExtension().lastPathComponent)
        }
        cache[id] = entry
        return entry
    }
}
