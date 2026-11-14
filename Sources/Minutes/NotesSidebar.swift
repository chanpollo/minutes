import AppKit
import SwiftUI

extension Color {
    /// The icon's red for the recording dots and glyphs: #d70015, the system red on dark. Filled buttons use `recordFill`.
    static let recording = Color(nsColor: .recordDot)
    static let notesPage = Color(nsColor: .textBackgroundColor)
    static let notesChrome = Color(nsColor: .windowBackgroundColor)
    static let notesAside = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.145, alpha: 1)
            : NSColor(srgbRed: 0.984, green: 0.984, blue: 0.992, alpha: 1)
    })
}

struct Sidebar: View {
    @ObservedObject var store: NotesStore
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let reduced = Motion.reduced(systemReduceMotion)
        let drag = store.drag
        let sections = store.sections
        let listed = sections.flatMap(\.items)
        VStack(spacing: 0) {
            SearchField(text: $store.query, prompt: "Search transcripts and notes")
                .padding(.horizontal, 10)
                .padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupsSection(store: store, drag: drag, reduced: reduced) { listFocused = true }
                    if sections.isEmpty {
                        Text(emptyText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    } else {
                        MeetingList(store: store, swipe: store.swipe, drag: drag, sections: sections, reduced: reduced) { id in
                            // A click with a row open only closes it.
                            guard !store.swipe.isOpen else { return store.swipe.close() }
                            Motion.animate(reduced ? nil : Motion.spring) { store.select(id) }
                            listFocused = true
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 16)
                // Room to scroll the last row clear of the Undo toast.
                .padding(.bottom, 64)
                .coordinateSpace(name: SidebarSwipeModel.space)
                .background(SidebarEvents(covered: store.toast == nil ? 0 : 48) { event, point in handle(event, at: point) })
                .onPreferenceChange(SwipeRowFrames.self) { store.swipe.rowFrames = $0 }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { step(-1, in: listed, reduced: reduced) }
            .onKeyPress(.downArrow) { step(1, in: listed, reduced: reduced) }
            // The toast sits above the New Note bar, over the last rows.
            .overlay(alignment: .bottom) {
                if let toast = store.toast {
                    UndoToast(toast: toast, undo: store.undoToast, hold: store.holdToast)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                        .id(toast.serial)
                        .transition(.asymmetric(insertion: reduced ? .opacity : .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                }
            }
            Divider()
            NewNoteBar { listFocused = false; store.newNote() }
        }
        .background(Color.notesChrome)
        .onChange(of: store.query) { store.swipe.close(animated: false) }
    }

    /// Trackpad swipes over a row, clicks that close an open row, Esc and ⌘Z.
    private func handle(_ event: NSEvent, at point: CGPoint?) -> Bool {
        switch event.type {
        case .scrollWheel:
            // SwiftUI says nothing when a drag ends without a drop; no button held means it is over.
            if store.drag.dragging != nil, NSEvent.pressedMouseButtons == 0 { store.drag.reset() }
            guard store.drag.dragging == nil, let input = SwipeInput(event) else { return false }
            let consumed = store.swipe.handle(input, row: point.flatMap(store.swipe.row(at:)))
            // Only a row left open takes the keys (Esc, arrows); a pin or a spring back leaves the focus where it was.
            let released = input.phase.contains(.ended) || input.phase.contains(.cancelled)
            if consumed, released, store.swipe.isOpen { listFocused = true }
            return consumed
        case .leftMouseDown:
            if store.drag.dragging != nil { store.drag.reset() }
            return store.swipe.click(at: point)
        case .rightMouseDown:
            _ = store.swipe.click(at: point)
            return false
        case .keyDown:
            return store.sidebarKey(event)
        default:
            return false
        }
    }

    private var emptyText: String {
        let query = store.query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return "No results for “\(query)”" }
        return store.showingArchived ? "No archived meetings" : "No meetings in this group"
    }

    private func step(_ delta: Int, in items: [MeetingItem], reduced: Bool) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let index = items.firstIndex { $0.id == store.selectedID }.map { $0 + delta } ?? 0
        Motion.animate(reduced ? nil : Motion.spring) { store.select(items[min(max(index, 0), items.count - 1)].id) }
        return .handled
    }
}

/// Pinned to the foot of the sidebar: a note dated now, in the chosen group, with nothing recorded.
private struct NewNoteBar: View {
    let make: () -> Void

    var body: some View {
        HStack {
            Button(action: make) {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                    Text("New Note")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("New Note (⌘N)")
            .accessibilityLabel("New Note")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Groups

private struct GroupsSection: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var drag: SidebarDragModel
    let reduced: Bool
    /// Clicking a row ends a name being typed, as clicking away does.
    let focusList: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(text: "Groups")
                Spacer()
                Button {
                    store.beginNewGroup()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Group")
                .accessibilityLabel("New Group")
            }
            .padding(.trailing, 2)
            GroupRow(name: "All meetings", count: store.count(in: nil), on: store.groupFilter == nil && !store.showingArchived,
                     targeted: drag.target == .all) { pick(nil) }
                .onDrop(of: [.minutesSidebarItem], delegate: SidebarDropDelegate(target: .all, drag: drag, store: store))
            ForEach(drag.displayed(store.groups)) { group in
                let count = store.count(in: group.id)
                GroupRow(name: group.name, count: count, on: store.groupFilter == group.id,
                         targeted: drag.target == .group(group.id), gap: drag.isGap(group.id),
                         editing: store.editingGroup == group.id ? store : nil, groupID: group.id) { pick(group.id) }
                    .opacity(drag.isGap(group.id) ? 0 : 1)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { store.beginRename(group.id) })
                    .modifier(GroupDragSource(drag: drag, group: group, count: count, enabled: store.editingGroup != group.id))
                    .onDrop(of: [.minutesSidebarItem], delegate: SidebarDropDelegate(target: .group(group.id), drag: drag, store: store))
                    .contextMenu {
                        Button("Rename…") { store.beginRename(group.id) }
                        Button("Delete") {
                            Ask.confirm(
                                "Delete the group “\(group.name)”?",
                                info: "Its meetings stay in All meetings, without a group.", button: "Delete Group"
                            ) { store.deleteGroup(group.id) }
                        }
                    }
                    .transition(Motion.row(reduced: reduced))
            }
            // Last while anything is archived; not a drop target and not draggable.
            if store.archivedCount > 0 {
                GroupRow(name: "Archived", count: store.archivedCount, on: store.showingArchived, symbol: "archivebox") {
                    pick(nil, archived: true)
                }
                .transition(Motion.row(reduced: reduced))
            }
        }
        .modifier(SelectionBackground(fill: Color.primary.opacity(0.09)))
        .animation(Motion.move(reduced: reduced), value: drag.insertion)
        .animation(Motion.fade, value: drag.target)
    }

    private func pick(_ id: String?, archived: Bool = false) {
        focusList()
        Motion.animate(Motion.move(reduced: reduced)) { store.pick(group: id, archived: archived) }
    }
}

/// A group row can be dragged, except while its name is being typed and the mouse selects text.
private struct GroupDragSource: ViewModifier {
    let drag: SidebarDragModel
    let group: MeetingGroup
    let count: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                drag.begin(.group(group.id))
            } preview: {
                GroupDragPreview(name: group.name, count: count)
            }
        } else {
            content
        }
    }
}

private struct GroupLabel: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .frame(width: 16)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct GroupRow: View {
    let name: String
    let count: Int
    let on: Bool
    var targeted = false
    var gap = false
    /// Set while the name is being typed.
    var editing: NotesStore?
    var groupID: String?
    var symbol = "folder"
    let pick: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 16)
            if let editing, let groupID {
                GroupNameField(store: editing, groupID: groupID)
            } else {
                Text(name)
                    .fontWeight(on ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, editing == nil ? 8 : 4)
        .padding(.vertical, 6)
        .background {
            if editing != nil, !on {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.09))
            }
        }
        .anchorPreference(key: SelectedRow.self, value: .bounds) { on && !gap ? $0 : nil }
        .background {
            if targeted {
                // A meeting held over the row.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
            }
        }
        .contentShape(Rectangle())
        // Clicks inside the name field place the cursor; they do not pick the row.
        .onTapGesture { if editing == nil { pick() } }
        .accessibilityElement(children: editing == nil ? .combine : .contain)
        .accessibilityLabel("\(name), \(count) meetings")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
    }
}

/// The group's name in place, as Finder renames a file: Return keeps it, Esc goes back.
private struct GroupNameField: View {
    @ObservedObject var store: NotesStore
    let groupID: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Group name", text: $store.editingDraft)
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.notesPage))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).padding(-2))
            // Laid out as one line of text, so the row keeps its height; the field draws into the row's padding.
            .frame(height: 16)
            .focused($focused)
            .accessibilityLabel("Group name")
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onSubmit { store.finishGroupEdit(groupID, name: store.editingDraft) }
            .onExitCommand { store.cancelGroupEdit(groupID) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { store.finishGroupEdit(groupID, name: store.editingDraft) }
            }
    }
}

/// The group choices for one meeting: in its context menu and behind the page's Group button.
struct GroupChoices: View {
    @ObservedObject var store: NotesStore
    let item: MeetingItem

    var body: some View {
        let current = store.groupID(of: item)
        ForEach(store.groups) { group in
            Toggle(group.name, isOn: Binding(get: { current == group.id }, set: { _ in store.move(item.id, to: group.id) }))
        }
        Toggle("No Group", isOn: Binding(get: { current == nil }, set: { _ in store.move(item.id, to: nil) }))
        Divider()
        Button("New Group") { store.beginNewGroup(moving: item.id) }
    }
}

// MARK: Meetings

/// Pinned and the day sections in one list, so a row pinned or unpinned moves to its new place; the selected row's
/// background slides between rows.
private struct MeetingList: View {
    @ObservedObject var store: NotesStore
    /// Only which row is swiped; the swipe's position is watched by that row alone.
    @ObservedObject var swipe: SidebarSwipeModel
    let drag: SidebarDragModel
    let sections: [MeetingSection]
    let reduced: Bool
    let pick: (String) -> Void
    @Environment(\.controlActiveState) private var activeState

    private enum Entry: Identifiable {
        case header(MeetingSection, first: Bool)
        case row(MeetingItem, pinned: Bool)

        var id: String {
            switch self {
            case .header(let section, _): "h:" + section.id
            case .row(let item, _): "m:" + item.id
            }
        }
    }

    var body: some View {
        let fill: Color = activeState == .key ? .accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        let entries = sections.enumerated().flatMap { index, section in
            [Entry.header(section, first: index == 0)] + section.items.map { Entry.row($0, pinned: section.pinned) }
        }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries) { entry in
                switch entry {
                case .header(let section, let first):
                    SectionLabel(text: section.label)
                        .padding(.top, first ? 0 : 14)
                        .padding(.bottom, 2)
                        .transition(Motion.row(reduced: reduced))
                case .row(let item, let pinned):
                    MeetingRow(store: store, track: swipe.rowID == item.id ? swipe.track : .idle, drag: drag, item: item,
                               state: rowState(item), inPinned: pinned, selectionFill: fill) {
                        pick(item.id)
                    }
                    .equatable()
                    .transition(Motion.row(reduced: reduced))
                }
            }
        }
        .modifier(SelectionBackground(fill: fill))
    }

    private func rowState(_ item: MeetingItem) -> MeetingRowState {
        let phase: MeetingRowState.Phase? = store.liveMeeting(item.id).map {
            switch $0.phase {
            case .recording: return .recording($0.startedAt)
            case .transcribing(let progress): return .transcribing(progress.map { Int($0 * 100) })
            case .queued: return .waiting
            }
        }
        return MeetingRowState(
            selected: store.selectedID == item.id, swiped: swipe.rowID == item.id,
            archivedTag: item.isArchived && store.isSearching && !store.showingArchived, phase: phase,
            canPin: store.canPin(item.id), canArchive: store.canArchive(item.id), canDelete: store.canDelete(item.id))
    }
}

/// What a row shows besides its meeting, worked out by the list so a row redraws only when its own values change.
struct MeetingRowState: Equatable {
    enum Phase: Equatable {
        case recording(Date)
        case transcribing(Int?)
        case waiting
    }

    var selected = false
    var swiped = false
    var archivedTag = false
    var phase: Phase?
    var canPin = false
    var canArchive = false
    var canDelete = false
}

private struct MeetingRow: View, Equatable {
    let store: NotesStore
    let track: SwipeTrack
    let drag: SidebarDragModel
    let item: MeetingItem
    let state: MeetingRowState
    let inPinned: Bool
    let selectionFill: Color
    let picked: () -> Void
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (a: MeetingRow, b: MeetingRow) -> Bool {
        a.track === b.track && a.state == b.state && a.inPinned == b.inPinned && a.selectionFill == b.selectionFill
            && a.item.folder == b.item.folder && a.item.hasSummary == b.item.hasSummary && a.item.transcribing == b.item.transcribing
            && a.item.isNote == b.item.isNote && MeetingLabel.key(a.item.meta) == MeetingLabel.key(b.item.meta)
    }

    var body: some View {
        let selected = state.selected
        let emphasized = selected && activeState == .key
        let secondary: Color = emphasized ? .white.opacity(0.85) : .secondary
        SwipeTracked(track: track, sides: { store.swipeSides(item.id) }, fill: selected ? selectionFill : .clear,
                     act: { store.swipeAction(item.id, $0) }) {
            MeetingLabel(item: item, state: state, secondary: secondary, inPinned: inPinned, emphasized: emphasized)
                .foregroundStyle(emphasized ? Color.white : Color.primary)
                // When the fill slides, the text turns white once the fill is nearly under it, never white on white.
                .transaction(value: emphasized) { transaction in
                    guard transaction.animation != nil else { return }
                    transaction.animation = Motion.reduced(reduceMotion) ? nil : emphasized ? Motion.textFollowsFill : Motion.fade
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .anchorPreference(key: SelectedRow.self, value: .bounds) { selected ? $0 : nil }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SwipeRowFrames.self, value: [item.id: proxy.frame(in: .named(SidebarSwipeModel.space))])
        })
        .contentShape(Rectangle())
        .onTapGesture(perform: picked)
        .onDrag {
            store.swipe.close(animated: false)
            return drag.begin(.meeting(item.id))
        } preview: {
            MeetingDragPreview(store: store, item: item)
        }
        .contextMenu { MeetingMenu(store: store, item: item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.select(item.id) }
        .accessibilityActions {
            if state.canPin {
                Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
            }
            if item.isArchived {
                Button("Unarchive") { store.setArchived(item.id, false) }
            } else if state.canArchive {
                Button("Archive") { store.setArchived(item.id, true) }
            }
            if state.canDelete {
                Button("Delete") { confirmDelete(store: store, item: item) }
            }
        }
    }
}

/// The swiped row follows its track on every frame; the others hold the idle one.
private struct SwipeTracked<Content: View>: View {
    @ObservedObject var track: SwipeTrack
    let sides: () -> SidebarSwipeModel.Sides
    let fill: Color
    let act: (SwipeAction) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        SwipeSurface(offset: track.offset, grow: track.armed ? 1 : 0, sides: sides, fill: fill, act: act) { content }
    }
}

/// Where the selected row is, so one background can slide between rows instead of each row drawing its own.
private struct SelectedRow: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private struct SelectionBackground: ViewModifier {
    let fill: Color

    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(SelectedRow.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let frame = proxy[anchor]
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }
}

struct MeetingDragPreview: View {
    let store: NotesStore
    let item: MeetingItem

    var body: some View {
        LiftedRow { MeetingLabel(item: item, state: MeetingRowState(), secondary: .secondary) }
    }
}

struct GroupDragPreview: View {
    let name: String
    let count: Int

    var body: some View {
        LiftedRow { GroupLabel(name: name, count: count) }
    }
}

/// Title and time, then the status line.
private struct MeetingLabel: View {
    let item: MeetingItem
    let state: MeetingRowState
    let secondary: Color
    /// Under Pinned, other days show `Yesterday` or the date instead of the time.
    var inPinned = false
    var emphasized = false

    /// What of the meta the row shows.
    static func key(_ meta: MeetingMeta) -> [String] {
        [meta.title, "\(meta.startedAt.timeIntervalSince1970)", "\(meta.endedAt?.timeIntervalSince1970 ?? -1)", meta.app ?? "",
         meta.transcriptError == nil ? "" : "!", "\(meta.pinnedAt?.timeIntervalSince1970 ?? -1)",
         "\(meta.archivedAt?.timeIntervalSince1970 ?? -1)", meta.groupID ?? "", meta.recordMode.rawValue]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // A note not yet named shows its placeholder quietly.
                Text(item.meta.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(item.isNote && item.meta.title == "Untitled" ? secondary : emphasized ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // The pin as text, so the row lines up on the time's baseline whether pinned or not.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if item.isPinned {
                        Text(Image(systemName: "pin.fill"))
                            .font(.system(size: 9))
                            .foregroundStyle(emphasized ? Color.white : Color.swipePin)
                            .accessibilityLabel("Pinned")
                    }
                    Text(inPinned ? MeetingFormat.pinnedTime(item.meta.startedAt) : MeetingFormat.time(item.meta.startedAt))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(secondary)
                }
            }
            HStack(spacing: 6) {
                if state.archivedTag {
                    ArchivedTag(emphasized: emphasized)
                }
                RowStatus(item: item, phase: state.phase)
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(secondary)
            .lineLimit(1)
        }
    }
}

/// Marks an archived meeting among search results and on its page.
struct ArchivedTag: View {
    var emphasized = false

    var body: some View {
        Text("Archived")
            .font(.system(size: 11))
            .padding(.horizontal, 5)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(emphasized ? Color.white.opacity(0.6) : Color.primary.opacity(0.18)))
            .foregroundStyle(emphasized ? Color.white : Color.secondary)
    }
}

/// `52 min · Google Meet`, or what is happening to the meeting now.
private struct RowStatus: View {
    let item: MeetingItem
    let phase: MeetingRowState.Phase?

    var body: some View {
        let app = item.meta.app
        if let phase {
            switch phase {
            case .recording(let startedAt):
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    HStack(spacing: 6) {
                        Circle().fill(Color.recording).frame(width: 7, height: 7)
                        Text("Recording · \(item.meta.recordMode.name) · "
                             + AppDelegate.clock(context.date.timeIntervalSince(startedAt)))
                    }
                }
            case .transcribing(let percent):
                Text(percent.map { "Transcribing · \($0)%" } ?? "Transcribing")
            case .waiting:
                Text("Waiting to transcribe")
            }
        } else if item.transcribing {
            Text("Transcribing")
        } else if item.meta.transcriptError != nil {
            Text(join("Transcription failed", app))
        } else {
            Text(MeetingFormat.rowLabel(item))
        }
    }

    private func join(_ status: String, _ app: String?) -> String {
        [status, app].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct MeetingMenu: View {
    @ObservedObject var store: NotesStore
    let item: MeetingItem

    var body: some View {
        let staged = store.isStaged(item.id)
        if item.isArchived {
            Button("Unarchive") { store.setArchived(item.id, false) }
                .keyboardShortcut("a", modifiers: [.command, .control])
        } else {
            Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!store.canPin(item.id))
            Button("Archive") { store.setArchived(item.id, true) }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(!store.canArchive(item.id))
        }
        Menu("Move to Group") { GroupChoices(store: store, item: item) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
            .disabled(staged)
        Divider()
        Button("Delete Meeting…") { confirmDelete(store: store, item: item) }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!store.canDelete(item.id))
    }
}

/// From a swiped row, the row stays open behind the question: Cancel closes it, Move to Trash slides it off.
func confirmDelete(store: NotesStore, item: MeetingItem) {
    let swiped = store.swipe.rowID == item.id
    Ask.confirm(
        "Delete “\(item.meta.title)”?",
        info: "The meeting folder, with its recording, transcript and notes, moves to the Trash.",
        button: "Move to Trash",
        cancelled: { if swiped { store.swipe.close() } }
    ) {
        if swiped, store.swipe.rowID == item.id {
            store.swipe.slideOff(item.id) { store.delete(item.id) }
        } else {
            store.delete(item.id)
        }
    }
}

/// "Archived …" or "Deleted …" for 5 s, with Undo.
private struct UndoToast: View {
    let toast: SidebarToast
    let undo: () -> Void
    let hold: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(toast.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: undo) {
                Text("Undo")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.toastText.opacity(0.16)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.toastText)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.toastInk))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
        .onHover(perform: hold)
        .accessibilityElement(children: .contain)
    }
}

private extension Color {
    static let toastInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xeb / 255, green: 0xeb / 255, blue: 0xeb / 255, alpha: 1)
            : NSColor(srgbRed: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255, alpha: 1)
    })
    static let toastText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255, alpha: 1)
            : .white
    })
}

// MARK: Search

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.controlSize = .large
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search meetings")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

// MARK: Alerts

/// Sheets on the key window, or modal alerts when there is none.
enum Ask {
    static func text(_ title: String, value: String = "", button: String, _ done: @escaping (String) -> Void) {
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        run(alert) { if $0 == .alertFirstButtonReturn { done(field.stringValue) } }
    }

    static func confirm(_ title: String, info: String, button: String, cancelled: (() -> Void)? = nil,
                        _ done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        run(alert) { response in
            if response == .alertFirstButtonReturn { done() } else { cancelled?() }
        }
    }

    private static func run(_ alert: NSAlert, _ finish: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
