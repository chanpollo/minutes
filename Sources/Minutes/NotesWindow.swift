import AppKit
import AVFoundation
import Combine
import os
import SwiftUI
import UniformTypeIdentifiers

/// The meetings window: groups and days in the sidebar, one page per meeting, notes.md beside it.
final class NotesWindowController: NSObject, NSWindowDelegate {
    static let shared = NotesWindowController()

    var onSummarise: ((_ meetingID: String, _ model: SummaryModel) -> Void)?
    var onChanged: ((_ meetingID: String) -> Void)?
    /// The window's Record / Stop button (`.windowButton`) and the Record Screen / Record Voice items under it.
    var onRecord: ((RecordEntry) -> Void)?
    /// The recording page's Stop recording button; does nothing when the recording already ended.
    var onStop: (() -> Void)?

    private var window: NSWindow?
    private let store = NotesStore()
    private let undoManager = SidebarUndoManager()

    private override init() {
        super.init()
        store.onSummarise = { [weak self] id, model in self?.onSummarise?(id, model) }
        store.onChanged = { [weak self] id in self?.onChanged?(id) }
        store.onError = { [weak self] error in self?.present(error) }
        store.onRecord = { [weak self] in self?.onRecord?($0) }
        store.onStop = { [weak self] in self?.onStop?() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
    }

    func show(meetingID: String? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        store.open(selecting: meetingID)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Older entry point: a recording without levels or app.
    func setRecording(start: Date?, title: String? = nil) {
        setLive(start.map {
            [LiveMeeting(id: "recording", title: title ?? "Meeting", app: nil, startedAt: $0, phase: .recording { (0, 0) })]
        } ?? [])
    }

    /// The meetings being recorded, transcribed or waiting to be, each shown live in the list and on its page.
    func setLive(_ live: [LiveMeeting]) {
        if Thread.isMainThread {
            store.setLive(live)
        } else {
            DispatchQueue.main.async { self.store.setLive(live) }
        }
    }

    func setBusy(_ meetingID: String, _ busy: Bool) {
        if Thread.isMainThread {
            store.setBusy(meetingID, busy)
        } else {
            DispatchQueue.main.async { self.store.setBusy(meetingID, busy) }
        }
    }

    /// Edit > Find: puts the cursor in the sidebar's search field.
    @objc func focusSearch() {
        guard let window, window.isVisible else { return }
        func field(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for subview in view.subviews {
                if let found = field(in: subview) { return found }
            }
            return nil
        }
        if let field = field(in: window.contentView?.superview ?? window.contentView ?? NSView()) {
            window.makeFirstResponder(field)
        }
    }

    /// View > Hide Notes / Show Notes: the Comments | Notes column beside the page. A note's page has none.
    @objc func toggleNotesColumn(_ sender: Any?) {
        guard store.hasAside else { return }
        store.toggleAside()
    }

    /// File › New Note (⌘N), the menu bar and the Dock: the window comes up if need be, with the new note selected.
    @objc func newNote(_ sender: Any?) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            show()
        }
        store.newNote()
    }

    /// The note on the page of the open window, for a recording started while it shows; nil for a meeting. The window
    /// has to be on screen: `isVisible` is also true on another Space or under another app's windows, and ⌃⌥R or the
    /// menu bar would then record into a note nobody is looking at.
    var openNote: MeetingMeta? {
        guard let window, Self.onScreen(window) else { return nil }
        return store.selectedNote
    }

    static func onScreen(_ window: NSWindow) -> Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        undoManager.store = store
        undoManager.window = window
        return undoManager
    }

    // The model can be changed elsewhere, e.g. in Settings.
    func windowDidBecomeKey(_ notification: Notification) {
        store.syncModel()
    }

    func windowWillClose(_ notification: Notification) {
        store.close()
    }

    @objc private func willTerminate() {
        store.saveNotes()
    }

    static let defaultSize = NSSize(width: 1440, height: 860)
    /// Windows saved at the old default open at the new one.
    private static let previousDefaultSize = NSSize(width: 1280, height: 820)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: Self.styleMask, backing: .buffered, defer: false)
        Self.configure(window, store: store)
        window.delegate = self
        if !window.setFrameUsingName("NotesWindow") {
            window.center()
        } else if window.contentView?.frame.size == Self.previousDefaultSize {
            Self.grow(window)
        }
        window.setFrameAutosaveName("NotesWindow")
        return window
    }

    /// Keeps the window's centre and stays on its screen.
    static func grow(_ window: NSWindow) {
        var frame = window.frame.insetBy(dx: (previousDefaultSize.width - defaultSize.width) / 2,
                                         dy: (previousDefaultSize.height - defaultSize.height) / 2)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: false)
    }

    /// One toolbar across the whole window (title in the middle, Record at the end) above the sidebar and the page.
    static func configure(_ window: NSWindow, store: NotesStore) {
        window.styleMask = styleMask
        window.title = "Minutes"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        let hosting = NSHostingController(rootView: NotesRootView(store: store))
        // Otherwise the window snaps to the SwiftUI ideal size.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 960, height: 560)
        window.setContentSize(defaultSize)
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// The window's undo. With the list in focus, Edit › Undo is the sidebar's last pin, archive or delete, named as such;
/// in a text field it is that field's typing.
final class SidebarUndoManager: UndoManager {
    weak var store: NotesStore?
    weak var window: NSWindow?

    private var sidebarFirst: Bool {
        guard let store, store.canUndo, let window else { return false }
        return !(window.firstResponder is NSText)
    }

    override var canUndo: Bool { sidebarFirst || super.canUndo }

    override var undoActionName: String {
        sidebarFirst ? store?.undoName ?? "" : super.undoActionName
    }

    override var undoMenuItemTitle: String {
        sidebarFirst ? undoMenuTitle(forUndoActionName: undoActionName) : super.undoMenuItemTitle
    }

    override func undo() {
        if sidebarFirst { store?.undoLast() } else { super.undo() }
    }
}

// MARK: Meeting menu

extension NotesWindowController: NSMenuItemValidation {
    @objc func pinMeeting(_ sender: Any?) { store.perform(.pin, for: store.menuTarget) }
    @objc func archiveMeeting(_ sender: Any?) { store.perform(.archive, for: store.menuTarget) }
    @objc func deleteMeeting(_ sender: Any?) { store.perform(.delete, for: store.menuTarget) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let command: NotesStore.SidebarCommand
        switch item.action {
        case #selector(pinMeeting): command = .pin
        case #selector(archiveMeeting): command = .archive
        case #selector(deleteMeeting): command = .delete
        case #selector(toggleNotesColumn(_:)):
            item.title = store.asideHidden ? "Show Notes" : "Hide Notes"
            return (window?.isKeyWindow ?? false) && store.hasAside
        default: return true
        }
        let state = store.command(command, for: store.menuTarget)
        item.title = state.title
        guard let window, window.isKeyWindow else { return false }
        // While typing, ⌘⌫ deletes to the start of the line.
        if command == .delete, (window.firstResponder as? NSTextView)?.isEditable == true { return false }
        return state.enabled
    }
}

struct MeetingItem: Identifiable {
    let folder: URL
    let meta: MeetingMeta
    var hasSummary = false
    var hasBriefing = false
    var transcribing = false
    /// Made with New Note and nothing recorded into it: its page is the notes editor.
    var isNote = false
    var id: String { meta.id }

    init(folder: URL, meta: MeetingMeta, staged: Bool = false) {
        self.folder = folder
        self.meta = meta
        let exists = { (name: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        hasSummary = exists("summary.md")
        hasBriefing = exists(Briefing.audioName)
        isNote = Workspace.isNote(folder, meta: meta)
        // No way to see the job queue from here; a recent recording with audio is most likely still being transcribed.
        let recent = Date().timeIntervalSince(meta.endedAt ?? meta.startedAt) < 3 * 3600
        transcribing = !staged && meta.transcriptError == nil && !exists("transcript.md") && recent
            && (exists("me.wav") || exists("others.wav"))
    }
}

struct MeetingPage {
    enum Transcript {
        case lines([TranscriptLine])
        case noSpeech, pending, missing

        var isPending: Bool {
            if case .pending = self { return true }
            return false
        }

        var hasLines: Bool {
            if case .lines = self { return true }
            return false
        }
    }

    let item: MeetingItem
    let media: MediaPlayer.Source
    let summary: [SummaryBlock]?
    let transcript: Transcript
    /// The recording is still in staging; nothing on the page can be changed yet except its group.
    var staged = false
}

/// A day, or Pinned, in the sidebar.
struct MeetingSection: Identifiable {
    let id: String
    let label: String
    let items: [MeetingItem]
    var pinned = false
}

/// One pin, unpin, archive, unarchive or delete, with what the meeting had before.
struct SidebarUndo {
    enum Change {
        case pin, unpin, archive, unarchive
        /// Where the Trash put the folder, and where it was.
        case delete(trashed: URL, folder: URL)
    }

    let change: Change
    let id: String
    let title: String
    let pinnedAt: Date?
    let archivedAt: Date?
    /// It was the selected meeting; undo selects it again.
    let selected: Bool
    let serial: Int
}

struct SidebarToast: Equatable {
    let serial: Int
    let text: String
}

final class NotesStore: ObservableObject {
    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    /// What the selected meeting's page shows below its header.
    enum PageState {
        case recording(LiveMeeting, levels: () -> (me: Float, others: Float))
        case transcribing(progress: Double?)
        /// Behind another meeting in the transcriber.
        case waiting
        case done
    }

    @Published private(set) var meetings: [MeetingItem] = [] { didSet { counts = nil } }
    /// `meetings` narrowed by the search query.
    @Published private(set) var visible: [MeetingItem] = []
    @Published private(set) var groups: [MeetingGroup] = [] { didSet { counts = nil } }
    /// nil shows all meetings.
    @Published var groupFilter: String?
    @Published private(set) var selectedID: String?
    @Published private(set) var page: MeetingPage? {
        didSet {
            comments.show(page)
            let video: Bool = { if case .video = page?.media { return true } else { return false } }()
            if notes.canPlay != video { notes.canPlay = video }
        }
    }
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var model = SummaryModel.current
    @Published var query = ""
    @Published var tab = Tab.summary
    /// Being recorded, transcribed or waiting for the transcriber; the recording first, then the transcriber's order.
    @Published private(set) var live: [LiveMeeting] = []
    /// Live meetings still in staging, listed with the workspace's meetings.
    @Published private(set) var liveItems: [MeetingItem] = [] { didSet { counts = nil } }
    /// The group whose name is being typed in the sidebar.
    @Published private(set) var editingGroup: String?
    /// The name as typed so far; kept here so starting another edit can save it.
    @Published var editingDraft = ""
    private var editingIsNew = false
    /// The meeting "New Group" put into the group being named, and the group it came from.
    private var editingMoved: (meetingID: String, from: String?)?
    /// The Archived entry under Groups is chosen; `groupFilter` is nil then.
    @Published private(set) var showingArchived = false
    /// "Archived …" or "Deleted …" with Undo, at the bottom of the sidebar.
    @Published private(set) var toast: SidebarToast?
    /// The picture shown large over the window.
    @Published private(set) var look: PictureLook?
    /// Counts Capture presses; the video flashes on each.
    @Published private(set) var captures = 0
    /// The Comments | Notes column is hidden and the page takes the full width.
    @Published private(set) var asideHidden = UserDefaults.standard.bool(forKey: NotesStore.asideHiddenKey)
    static let asideHiddenKey = "notesAsideHidden"
    /// The note New Note just made: its title field opens empty, with the caret in it.
    @Published private(set) var freshNote: String?

    let player = MediaPlayer()
    /// Kept apart from the store so typing in the panel does not redraw the page.
    let notes = NotesDocument()
    let drag = SidebarDragModel()
    let swipe = SidebarSwipeModel()
    let comments = CommentsModel()
    var onSummarise: ((String, SummaryModel) -> Void)?
    var onChanged: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var onRecord: ((RecordEntry) -> Void)?
    var onStop: (() -> Void)?

    private var isOpen = false
    // Nothing animates while the window first fills.
    private var populated = false
    private var pageShown = false
    private var queryWatch: AnyCancellable?
    private var revealWatch: AnyCancellable?
    // Set by the window's Record button, so the recording it starts is selected when it shows up.
    private var selectNextLive = false
    private var refocusNotes = false
    private var undoStack: [SidebarUndo] = []
    private var undoSerial = 0
    private var toastTimer: DispatchWorkItem?
    static var toastDuration: TimeInterval = 5

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(meetingsChanged), name: .meetingsChanged, object: nil)
        notes.folder = { [weak self] id in
            guard let self else { return nil }
            guard isStaged(id) else { return item(id)?.folder }
            // Moved into the workspace since the list was last read.
            if let folder = stagedFolders[id], FileManager.default.fileExists(atPath: folder.path) { return folder }
            return Workspace.folder(id: id)
        }
        notes.onSaved = { [weak self] id in
            // Staged notes move into the workspace with the recording; Sync takes them from there.
            if self?.isStaged(id) == false { self?.onChanged?(id) }
        }
        notes.onError = { [weak self] in self?.onError?($0) }
        comments.folder = { [weak self] in self?.item($0)?.folder }
        comments.onSaved = { [weak self] in self?.onChanged?($0) }
        comments.onError = { [weak self] in self?.onError?($0) }
        comments.currentTab = { [weak self] in self?.tab == .transcript ? .transcript : .summary }
        comments.onTab = { [weak self] target in
            Motion.animate(Motion.fade) { self?.tab = target == .transcript ? .transcript : .summary }
        }
        notes.play = { [weak self] in self?.player.seek(to: $0, play: true) }
        notes.open = { [weak self] in self?.open($0) }
        swipe.sides = { [weak self] in self?.swipeSides($0) ?? .none }
        swipe.fire = { [weak self] in self?.swipeAction($0, $1) }
        queryWatch = $query.removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.filter($0) }
        // Writing or opening a comment needs the column.
        revealWatch = comments.$cardScroll.dropFirst().compactMap { $0 }
            .sink { [weak self] _ in self?.showAside() }
    }

    func toggleAside() {
        setAside(hidden: !asideHidden)
    }

    func showAside() {
        if asideHidden { setAside(hidden: false) }
    }

    private func setAside(hidden: Bool) {
        let window = NSApp.keyWindow
        if hidden { refocusNotes = window?.firstResponder is NotesTextView }
        Motion.animate(Motion.reduceMotion ? Motion.fade : Motion.appear) { asideHidden = hidden }
        UserDefaults.standard.set(hidden, forKey: Self.asideHiddenKey)
        guard !hidden, refocusNotes else { return }
        refocusNotes = false
        // The notes being typed in when the column hid get the caret back once it is there again.
        DispatchQueue.main.async { [weak window] in
            func find(_ view: NSView?) -> NotesTextView? {
                guard let view else { return nil }
                return view as? NotesTextView ?? view.subviews.lazy.compactMap(find).first
            }
            if let window, let notes = find(window.contentView) { window.makeFirstResponder(notes) }
        }
    }

    func open(selecting id: String?) {
        isOpen = true
        populated = false
        pageShown = false
        reload(preferring: id)
    }

    func close() {
        saveNotes()
        notes.cleanAttachments()
        isOpen = false
        rememberPosition()
        player.unload()
    }

    @objc private func meetingsChanged() {
        if isOpen { reload() }
    }

    func reload(preferring preferred: String? = nil) {
        syncModel()
        let groups = Workspace.groups()
        let meetings = Workspace.meetings().map { MeetingItem(folder: $0.folder, meta: $0.meta) }
        let changed = Self.listKey(meetings, groups) != Self.listKey(self.meetings, self.groups)
        Motion.animate(populated && changed ? Motion.move() : nil) {
            self.groups = groups
            if let filter = groupFilter, !groups.contains(where: { $0.id == filter }) { groupFilter = nil }
            self.meetings = meetings
            // The last archived meeting left: back to All meetings.
            if showingArchived, !meetings.contains(where: \.isArchived) { showingArchived = false }
            refreshLiveItems()
            filter(query)
            let ids = Set(meetings.map(\.id) + liveItems.map(\.id))
            let target = [preferred, selectedID].compactMap { $0 }.first(where: ids.contains)
                ?? liveItems.first?.id ?? listed.first?.id ?? meetings.first?.id
            if target != selectedID {
                select(target)
            } else {
                loadPage()
            }
        }
        populated = isOpen
    }

    /// What the sidebar shows of the workspace: which meetings, in which groups, and the groups' order.
    private static func listKey(_ meetings: [MeetingItem], _ groups: [MeetingGroup]) -> [String] {
        meetings.map { $0.id + "/" + ($0.meta.groupID ?? "") } + groups.map { "g/" + $0.id + "/" + $0.name }
    }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        saveNotes()
        selectedID = id
        if freshNote != id { freshNote = nil }
        loadPage()
        notes.load(id)
    }

    /// New Note: an empty note dated now, in the chosen group, selected with its title ready to be typed. A search
    /// would hide it, so it is cleared.
    func newNote() {
        finishCurrentGroupEdit()
        saveNotes()
        swipe.close(animated: false)
        do {
            let made = try Workspace.makeNote(groupID: showingArchived ? nil : groupFilter)
            if !query.isEmpty { query = "" }
            if showingArchived { showingArchived = false }
            freshNote = made.meta.id
            Motion.animate(populated ? Motion.move() : nil) { reload(preferring: made.meta.id) }
            onChanged?(made.meta.id)
        } catch {
            onError?(error)
        }
    }

    /// The selected note, when nothing is being recorded into it yet.
    var selectedNote: MeetingMeta? {
        guard let id = selectedID, let item = item(id), item.isNote, !isStaged(id), liveMeeting(id) == nil else { return nil }
        return item.meta
    }

    /// Workspace meetings and the staged live ones.
    func item(_ id: String) -> MeetingItem? {
        meetings.first { $0.id == id } ?? liveItems.first { $0.id == id }
    }

    /// Still in staging: nothing on its page can be changed yet except its group and pin.
    func isStaged(_ id: String) -> Bool {
        liveItems.contains { $0.id == id }
    }

    func liveMeeting(_ id: String) -> LiveMeeting? {
        live.first { $0.id == id }
    }

    /// The sidebar's meetings in order: Pinned, then the days.
    var listed: [MeetingItem] {
        sections.flatMap(\.items)
    }

    var isSearching: Bool {
        !Self.fold(query.trimmingCharacters(in: .whitespaces)).isEmpty
    }

    /// Search results narrowed to the chosen group, staged live meetings among them by start. Archived meetings are
    /// listed only in Archived and in search results; pinned ones go above the days, newest pin first, except in those two.
    var sections: [MeetingSection] {
        let words = Self.fold(query.trimmingCharacters(in: .whitespaces))
        let staged = liveItems.filter { words.isEmpty || Self.fold($0.meta.title).contains(words) }
        let all = staged.isEmpty ? visible : (staged + visible).sorted { $0.meta.startedAt > $1.meta.startedAt }
        let rows = all.filter { item in
            if showingArchived { return item.isArchived }
            guard groupFilter == nil || groupID(of: item) == groupFilter else { return false }
            return !words.isEmpty || !item.isArchived
        }
        let pinned = words.isEmpty && !showingArchived
            ? rows.filter(\.isPinned).sorted { ($0.meta.pinnedAt!, $0.meta.startedAt) > ($1.meta.pinnedAt!, $1.meta.startedAt) } : []
        let pinnedIDs = Set(pinned.map(\.id))
        let days = MeetingFormat.groups(rows.filter { !pinnedIDs.contains($0.id) }).map {
            MeetingSection(id: "day-\(Int($0.day.timeIntervalSince1970))", label: $0.label, items: $0.items)
        }
        return (pinned.isEmpty ? [] : [MeetingSection(id: "pinned", label: "Pinned", items: pinned, pinned: true)]) + days
    }

    /// The meeting's group, or nil when it has none or its group was deleted.
    func groupID(of item: MeetingItem) -> String? {
        item.meta.groupID.flatMap { id in groups.contains { $0.id == id } ? id : nil }
    }

    /// Group id to count, "" for all meetings; worked out again only when the list changes.
    private var counts: [String: Int]?

    /// Archived meetings are counted only under Archived.
    func count(in group: String?) -> Int {
        if counts == nil {
            let ids = Set(groups.map(\.id))
            var tally: [String: Int] = [:]
            for item in meetings + liveItems where !item.isArchived {
                tally["", default: 0] += 1
                if let id = item.meta.groupID, ids.contains(id) { tally[id, default: 0] += 1 }
            }
            counts = tally
        }
        return counts?[group ?? ""] ?? 0
    }

    var archivedCount: Int {
        meetings.filter(\.isArchived).count
    }

    /// A row under Groups: a group, All meetings (nil), or Archived.
    func pick(group id: String?, archived: Bool = false) {
        swipe.close(animated: false)
        groupFilter = archived ? nil : id
        showingArchived = archived && archivedCount > 0
    }

    func groupName(_ id: String?) -> String? {
        id.flatMap { id in groups.first { $0.id == id }?.name }
    }

    /// A finished meeting's page has the Comments | Notes column, a recording or transcribing one a Notes column; a
    /// finished note's page is the notes themselves.
    var hasAside: Bool {
        guard let page else { return false }
        if case .done = state(of: page) { return !page.item.isNote }
        return !isStaged(page.item.id) || stagedFolders[page.item.id] != nil
    }

    func state(of page: MeetingPage) -> PageState {
        if let live = liveMeeting(page.item.id) {
            switch live.phase {
            case .recording(let levels): return .recording(live, levels: levels)
            case .transcribing(let progress): return .transcribing(progress: progress)
            case .queued: return .waiting
            }
        }
        return page.transcript.isPending ? .transcribing(progress: nil) : .done
    }

    // MARK: Live

    func setLive(_ new: [LiveMeeting]) {
        let previous = live
        let before = Set(previous.map(\.id)), after = Set(new.map(\.id))
        // A meeting that comes or goes slides in the list; progress updates do not animate it.
        Motion.animate(populated && before != after ? Motion.move() : nil) {
            live = new
            refreshLiveItems()
            // The window's Record button shows the new recording, unless the page is a transcript still being made:
            // switching away from it would look as if the recording took its place.
            if selectNextLive, let started = new.first(where: { $0.isRecording && !before.contains($0.id) }) {
                selectNextLive = false
                if selectedID.flatMap(liveMeeting) == nil { select(started.id) }
            } else if let selectedID, item(selectedID) != nil,
                      Self.phase(of: selectedID, in: previous) != Self.phase(of: selectedID, in: new) {
                loadPage()
            }
        }
        // A meeting that left the list is read again from the workspace, or its page would be left blank.
        if !before.subtracting(after).isEmpty, isOpen { reload() }
    }

    private static func phase(of id: String, in live: [LiveMeeting]) -> PageState.Kind? {
        live.first { $0.id == id }.map {
            switch $0.phase {
            case .recording: return .recording
            case .transcribing: return .transcribing
            case .queued: return .waiting
            }
        }
    }

    /// The Record button's own click: starts in the default mode, or stops.
    func record() {
        selectNextLive = !isRecording
        onRecord?(.windowButton)
    }

    /// An item under the Record button's arrow: starts in that mode and makes it the default.
    func record(_ mode: RecordMode) {
        guard !isRecording else { return }
        selectNextLive = true
        onRecord?(.menu(mode))
    }

    var isRecording: Bool {
        live.contains(where: \.isRecording)
    }

    /// Where each staged live meeting is, by id.
    private var stagedFolders: [String: URL] = [:]

    private static func findStaged(_ ids: Set<String>) -> [String: URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Workspace.staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var found: [String: URL] = [:]
        for folder in folders {
            if let id = Workspace.readMeta(folder)?.id, ids.contains(id) { found[id] = folder }
        }
        return found
    }

    /// Lists the live meetings not yet moved into the workspace. A folder moved in since is dropped here and the
    /// meeting is listed from the workspace once it is read again.
    private func refreshLiveItems() {
        let workspace = Set(meetings.map(\.id))
        let staged = live.filter { !workspace.contains($0.id) }
        let ids = Set(staged.map(\.id))
        let files = FileManager.default
        stagedFolders = stagedFolders.filter { ids.contains($0.key) && files.fileExists(atPath: $0.value.path) }
        let missing = ids.subtracting(stagedFolders.keys)
        if !missing.isEmpty { stagedFolders.merge(Self.findStaged(missing)) { $1 } }
        var seen = Set<String>()
        let items = staged.filter { seen.insert($0.id).inserted }.map { live in
            let folder = stagedFolders[live.id]
            var meta = folder.flatMap(Workspace.readMeta)
                ?? MeetingMeta(id: live.id, title: live.title, startedAt: live.startedAt, app: live.app)
            meta.title = live.title
            meta.app = live.app ?? meta.app
            meta.mode = meta.mode ?? live.mode
            return MeetingItem(folder: folder ?? Workspace.staging, meta: meta, staged: true)
        }
        if !items.isEmpty || !liveItems.isEmpty { liveItems = items }
    }

    // MARK: Page

    private let pageQueue = DispatchQueue(label: "Minutes.page", qos: .userInitiated)
    private let latestPage = OSAllocatedUnfairLock(initialState: 0)
    private var playerMeetingID: String?
    private var positions: [String: TimeInterval] = [:]

    /// Reads and parses the selected meeting's files off the main thread; the previous page stays until it is ready.
    private func loadPage() {
        let generation = latestPage.withLock { value -> Int in
            value += 1
            return value
        }
        guard let item = selectedID.flatMap(item) else {
            show(nil)
            loadMedia(.none, for: nil)
            return
        }
        if isStaged(item.id) {
            show(MeetingPage(item: item, media: .none, summary: nil, transcript: .pending, staged: true))
            loadMedia(.none, for: nil)
            return
        }
        pageQueue.async { [weak self, latestPage] in
            // Arrowing through the list queues a load per row; only the last one is worth parsing.
            guard latestPage.withLock({ $0 }) == generation else { return }
            let page = Self.makePage(item)
            DispatchQueue.main.async {
                guard let self, latestPage.withLock({ $0 }) == generation else { return }
                self.show(page)
                self.loadMedia(page.media, for: item.id)
            }
        }
    }

    /// Another meeting crossfades in; the same meeting crossfades only what changed on it.
    private func show(_ new: MeetingPage?) {
        let animation: Animation? = pageShown ? (new?.item.id == page?.item.id ? Motion.appear : Motion.fade) : nil
        Motion.animate(animation) { page = new }
        pageShown = isOpen
    }

    private func loadMedia(_ media: MediaPlayer.Source, for id: String?) {
        guard isOpen, media != player.source else { return }
        rememberPosition()
        playerMeetingID = id
        player.load(media, at: id.flatMap { positions[$0] } ?? 0)
    }

    private func rememberPosition() {
        if let id = playerMeetingID, player.source != .none { positions[id] = player.time }
    }

    /// me and others, as FLAC once compressed or WAV before.
    static func tracks(in folder: URL) -> [URL] {
        AudioTracks.existing(in: folder)
    }

    static func makePage(_ item: MeetingItem) -> MeetingPage {
        let file = { (name: String) in item.folder.appendingPathComponent(name) }
        let exists = { (name: String) in FileManager.default.fileExists(atPath: file(name).path) }

        let tracks = tracks(in: item.folder)
        let media: MediaPlayer.Source = exists("meeting.mp4") ? .video(file("meeting.mp4")) : tracks.isEmpty ? .none : .audio(tracks)

        let summary = (try? String(contentsOf: file("summary.md"), encoding: .utf8)).map(SummaryMarkdown.parse)
        // Typeset here, off the main thread, rather than while the page is first laid out.
        if let summary { SummaryText.prepare(summary) }
        // Thumbnails are made here, off the main thread, rather than while the page draws.
        Frames.referenced(in: item.folder).forEach { _ = FrameThumbnails.image(file($0)) }

        let transcript: MeetingPage.Transcript
        if let text = try? String(contentsOf: file("transcript.md"), encoding: .utf8) {
            let parsed = TranscriptParser.parse(text)
            transcript = parsed.isEmpty ? .noSpeech : .lines(parsed)
        } else {
            transcript = item.transcribing ? .pending : .missing
        }
        return MeetingPage(item: item, media: media, summary: summary, transcript: transcript)
    }

    // MARK: Search

    private struct SearchEntry {
        let folder: URL
        let modified: [Date?]
        let text: String
    }

    private let searchQueue = DispatchQueue(label: "Minutes.search", qos: .userInitiated)
    private var searchIndex: [String: SearchEntry] = [:]
    private var searchGeneration = 0
    static let searchedFiles = ["transcript.md", "notes.md", CommentFile.name]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Matches titles, transcripts and notes off the main thread, reading a file again only when it changed on disk.
    private func filter(_ raw: String) {
        searchGeneration += 1
        let query = Self.fold(raw.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else {
            visible = meetings
            return
        }
        let generation = searchGeneration
        let items = meetings
        let known = searchIndex
        searchQueue.async { [weak self] in
            var fresh: [String: SearchEntry] = [:]
            let found = items.filter { item in
                if Self.fold(item.meta.title).range(of: query, options: .literal) != nil { return true }
                let files = Self.searchedFiles.map { item.folder.appendingPathComponent($0) }
                let modified = files.map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
                var entry = known[item.id]
                if entry == nil || entry?.folder != item.folder || entry?.modified != modified {
                    let text = files.map { file in
                        file.lastPathComponent == CommentFile.name
                            ? CommentFile.searchText(file) : (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    }.joined(separator: "\n")
                    entry = SearchEntry(folder: item.folder, modified: modified, text: Self.fold(text))
                    fresh[item.id] = entry
                }
                return entry?.text.range(of: query, options: .literal) != nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.searchIndex.merge(fresh) { $1 }
                if generation == self.searchGeneration { self.visible = found }
            }
        }
    }

    // MARK: Actions

    /// Returns false when the rename failed, so the title field can revert.
    func rename(_ id: String, to title: String) -> Bool {
        guard let item = item(id), !isStaged(id), liveMeeting(id) == nil else { return false }
        // Focus loss and the field going away can both commit the same edit.
        guard title.trimmingCharacters(in: .whitespacesAndNewlines) != item.meta.title else { return true }
        do {
            _ = try Workspace.rename(item.folder, to: title)
            if freshNote == id { freshNote = nil }
            reload()
            onChanged?(id)
            return true
        } catch {
            // Workspace.rename writes meta.json before it moves the folder.
            _ = try? Workspace.updateMeta(item.folder) { $0.title = item.meta.title }
            reload()
            onError?(error)
            return false
        }
    }

    /// Names the meeting after another calendar event that was on when it began, with that event's invitees.
    func useEvent(_ event: CalendarEvent, for id: String) {
        guard let item = item(id), !isStaged(id), liveMeeting(id) == nil else { return }
        do {
            try Summarizer.useEvent(event, for: item.folder, byHand: true)
            reload()
            onChanged?(id)
        } catch {
            reload()
            onError?(error)
        }
    }

    /// Puts `name` in place of `speaker` in every turn of the meeting's transcript.md.
    func renameSpeaker(_ speaker: String, to name: String, in id: String) {
        // A newline or "*" would break the `**[hh:mm:ss] Label:**` marker.
        let name = name.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        // Me and Others name a track: renamed to one, the turns could not be told apart or renamed back.
        guard !name.isEmpty, name != speaker, TranscriptLine.canRename(speaker), TranscriptLine.canRename(name),
              let folder = item(id)?.folder
        else { return }
        let url = folder.appendingPathComponent("transcript.md")
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            try TranscriptParser.renaming(speaker, to: name, in: text).write(to: url, atomically: true, encoding: .utf8)
            CommentFile.refreshMarkdown(folder)
            reload()
            onChanged?(id)
        } catch {
            onError?(error)
        }
    }

    func setConfidential(_ on: Bool, for id: String) {
        guard let item = item(id) else { return }
        do {
            try Workspace.updateMeta(item.folder) {
                $0.confidential = on
                if on { $0.sentAnyway = nil }
            }
            reload()
            onChanged?(id)
        } catch {
            onError?(error)
        }
    }

    /// Moves the meeting's folder to the Trash; the caller has asked first. The next row, or the one before, is selected.
    /// Undo puts the folder back from the Trash.
    func delete(_ id: String) {
        // Asked again: a summary or transcription may have started while the question was up.
        guard let item = item(id), canDelete(id) else { return }
        let wasSelected = selectedID == id
        var next: String?
        if selectedID == id {
            saveNotes()
            next = selection(afterRemoving: id)
        }
        if playerMeetingID == id {
            player.unload()
            playerMeetingID = nil
        }
        let meta = Workspace.readMeta(item.folder) ?? item.meta
        FrameExtractor.shared.cancel(meetingID: id)
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: item.folder, resultingItemURL: &trashed)
            positions[id] = nil
            Sync.shared.meetingDeleted(meta)
            if isOpen { removed(selecting: next) }
            Workspace.notifyChanged()
            if let trashed = trashed as URL? {
                remember(item, .delete(trashed: trashed, folder: item.folder), selected: wasSelected)
            }
        } catch {
            onError?(error)
        }
    }

    /// A meeting left the list. The selection moves first, without sliding; then the row collapses and the newly
    /// selected row carries its background up with it.
    func removed(selecting next: String?) {
        guard let next else { return reload() }
        select(next)
        DispatchQueue.main.async { [weak self] in self?.reload(preferring: next) }
    }

    /// The row below, or the one above when it was the last.
    func selection(afterRemoving id: String) -> String? {
        let rows = listed.map(\.id)
        guard let index = rows.firstIndex(of: id) else { return nil }
        return index + 1 < rows.count ? rows[index + 1] : index > 0 ? rows[index - 1] : nil
    }

    func export(_ id: String, to url: URL) {
        guard let item = item(id) else { return }
        let read = { (name: String) in try? String(contentsOf: item.folder.appendingPathComponent(name), encoding: .utf8) }
        if selectedID == id { saveNotes() }
        let documents = CommentFile.documents(in: item.folder)
        let comments = CommentFile.section(
            CommentFile.read(item.folder), summary: documents.summary, transcript: documents.transcript, level: 3)
        let fm = FileManager.default
        let pictures = Sync.pictures(in: item.folder).filter { fm.fileExists(atPath: item.folder.appendingPathComponent($0).path) }
        let assets = Self.exportAssetsName(for: url)
        let text = Self.exportText(
            meta: item.meta, summary: read("summary.md"), notes: read("notes.md"),
            transcript: read("transcript.md").map(TranscriptParser.parse) ?? [], comments: comments,
            assets: pictures.isEmpty ? nil : assets, briefing: read(Briefing.scriptName), note: item.isNote)
        do {
            // Only the pictures the text shows; anything else already in that folder is left alone.
            let folder = url.deletingLastPathComponent().appendingPathComponent(assets, isDirectory: true)
            for path in pictures {
                let target = folder.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: item.folder.appendingPathComponent(path), to: target)
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            onError?(error)
        }
    }

    /// `Sprint review.md` keeps its pictures in `Sprint review.assets/frames/…` and `…/attachments/…` beside it.
    static func exportAssetsName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent + ".assets"
    }

    private static let pictureLinkPattern = try! NSRegularExpression(pattern: #"(!\[[^\]\n]*\]\()((?:frames|attachments)/)"#)

    /// Picture links into frames/ and attachments/ pointed into `assets`, the folder exported beside the file.
    static func exportLinks(_ markdown: String, assets: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()[]<> ")
        let prefix = (assets.addingPercentEncoding(withAllowedCharacters: allowed) ?? assets) + "/"
        let range = NSRange(location: 0, length: (markdown as NSString).length)
        return pictureLinkPattern.stringByReplacingMatches(
            in: markdown, range: range, withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: prefix) + "$2")
    }

    /// One Markdown file: title, meta line, invitees, summary, briefing script, notes, comments, transcript. A note
    /// has only the title, its line and the notes.
    static func exportText(meta: MeetingMeta, summary: String?, notes: String?, transcript: [TranscriptLine], comments: String? = nil,
                           assets: String? = nil, briefing: String? = nil, note: Bool = false) -> String {
        let summary = assets.flatMap { assets in summary.map { exportLinks($0, assets: assets) } } ?? summary
        let notes = assets.flatMap { assets in notes.map { exportLinks($0, assets: assets) } } ?? notes
        var parts = ["# \(meta.title)", note ? MeetingFormat.noteLine(meta) : MeetingFormat.metaLine(meta)]
        if let attendees = meta.attendees, !attendees.isEmpty {
            parts.append("Invited: " + attendees.joined(separator: ", "))
        }
        if let summary {
            // Its own title and stamp line are dropped; its sections go one level down under "Summary".
            var rows = summary.components(separatedBy: .newlines)
            if rows.first?.hasPrefix("# ") == true { rows.removeFirst() }
            while let first = rows.first, first.trimmingCharacters(in: .whitespaces).isEmpty || first.contains(" · Summarised by ") {
                rows.removeFirst()
            }
            let body = rows.map { $0.hasPrefix("#") ? "#" + $0 : $0 }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { parts.append("## Summary\n\n" + body) }
        }
        if let briefing = briefing.map(Briefing.parse), !briefing.isEmpty {
            parts.append("## Briefing\n\n" + briefing.map { $0.joined(separator: " ") }.joined(separator: "\n\n"))
        }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            parts.append("## Notes\n\n" + notes)
        }
        if let comments = comments?.trimmingCharacters(in: .whitespacesAndNewlines), !comments.isEmpty {
            parts.append("## Comments\n\n" + comments)
        }
        if !transcript.isEmpty {
            let turns = transcript.map { "**[\(MeetingFormat.longClock($0.time))] \($0.speaker):** \($0.text)" }
            parts.append("## Transcript\n\n" + turns.joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: Pin, archive, undo

    /// Being recorded or transcribed, or waiting for the transcriber: it can be pinned, not archived or deleted.
    func isLive(_ id: String) -> Bool {
        liveMeeting(id) != nil || isStaged(id) || meetings.first(where: { $0.id == id })?.transcribing == true
    }

    func canPin(_ id: String) -> Bool {
        guard let item = item(id), !item.isArchived else { return false }
        return !isStaged(id) || stagedFolders[id] != nil
    }

    func canArchive(_ id: String) -> Bool {
        item(id) != nil && !isLive(id)
    }

    func canDelete(_ id: String) -> Bool {
        item(id) != nil && !isLive(id) && !isBusy(id)
    }

    func swipeSides(_ id: String) -> SidebarSwipeModel.Sides {
        guard let item = item(id) else { return .none }
        if item.isArchived { return .init(trail: [.delete, .unarchive]) }
        return .init(lead: canPin(id) ? [item.isPinned ? .unpin : .pin] : [], trail: [.delete, .archive], trailDisabled: isLive(id))
    }

    /// A swipe button, or letting go past the full-swipe point.
    func swipeAction(_ id: String, _ action: SwipeAction) {
        switch action {
        case .pin, .unpin:
            swipe.close()
            togglePin(id)
        case .archive, .unarchive:
            let on = action == .archive
            guard !on || canArchive(id) else { return swipe.close() }
            if stays(archived: on) {
                swipe.close()
                setArchived(id, on)
            } else {
                swipe.slideOff(id) { [weak self] in self?.setArchived(id, on) }
            }
        case .delete:
            // The row stays open behind the question.
            guard let item = item(id), canDelete(id) else { return }
            confirmDelete(store: self, item: item)
        }
    }

    /// Whether a row is still listed once archived or unarchived: search shows both, Archived only archived ones.
    private func stays(archived: Bool) -> Bool {
        isSearching || showingArchived == archived
    }

    func togglePin(_ id: String) {
        guard canPin(id), let item = item(id) else { return }
        // meta.json keeps whole seconds; a pin a moment after another still goes above it.
        let latest = meetings.compactMap { $0.isPinned ? $0.meta.pinnedAt : nil }.max()
        let now = max(Date(), latest.map { $0.addingTimeInterval(1) } ?? .distantPast)
        guard writeSidebarMeta(item, pinnedAt: item.isPinned ? nil : now, archivedAt: nil,
                               animation: Motion.reduceMotion ? nil : Motion.swipeSpring) else { return }
        remember(item, item.isPinned ? .unpin : .pin, selected: selectedID == id)
    }

    /// Archiving clears the pin; the row leaves the list unless searching, and the selection moves on first.
    func setArchived(_ id: String, _ on: Bool) {
        guard let item = item(id), item.isArchived != on, !on || canArchive(id) else { return }
        let wasSelected = selectedID == id
        // Unarchiving the last one goes back to All meetings, where the meeting is listed again.
        let leaves = !stays(archived: on) && !(showingArchived && archivedCount == 1)
        if wasSelected, leaves { select(selection(afterRemoving: id)) }
        guard writeSidebarMeta(item, pinnedAt: on ? nil : item.meta.pinnedAt, archivedAt: on ? Date() : nil,
                               animation: Motion.reduceMotion ? Motion.fade : Motion.slideOff) else { return }
        remember(item, on ? .archive : .unarchive, selected: wasSelected)
    }

    /// pinnedAt and archivedAt belong to the sidebar: meta.json changes, Sync is not told. Only that meeting's row
    /// and page are updated; nothing else is read again.
    @discardableResult
    private func writeSidebarMeta(_ item: MeetingItem, pinnedAt: Date?, archivedAt: Date?, animation: Animation?) -> Bool {
        guard let folder = isStaged(item.id) ? stagedFolders[item.id] : item.folder else { return false }
        let meta: MeetingMeta
        do {
            meta = try Workspace.updateMeta(folder) {
                $0.pinnedAt = pinnedAt
                $0.archivedAt = archivedAt
            }
        } catch {
            onError?(error)
            return false
        }
        Motion.animate(populated ? animation : nil) { replace(item.id, meta: meta) }
        return true
    }

    private func replace(_ id: String, meta: MeetingMeta) {
        if let index = meetings.firstIndex(where: { $0.id == id }) {
            let updated = MeetingItem(folder: meetings[index].folder, meta: meta)
            meetings[index] = updated
            if let shown = visible.firstIndex(where: { $0.id == id }) { visible[shown] = updated }
            if let page, page.item.id == id {
                self.page = MeetingPage(item: updated, media: page.media, summary: page.summary, transcript: page.transcript,
                                        staged: page.staged)
            }
        } else if isStaged(id) {
            refreshLiveItems()
        }
        // The last archived meeting left: back to All meetings.
        if showingArchived, !meetings.contains(where: \.isArchived) { showingArchived = false }
    }

    private func remember(_ item: MeetingItem, _ change: SidebarUndo.Change, selected: Bool) {
        undoSerial += 1
        let entry = SidebarUndo(change: change, id: item.id, title: item.meta.title, pinnedAt: item.meta.pinnedAt,
                                archivedAt: item.meta.archivedAt, selected: selected, serial: undoSerial)
        undoStack.append(entry)
        if undoStack.count > 50 { undoStack.removeFirst() }
        switch change {
        case .archive: showToast("Archived “\(item.meta.title)”", serial: entry.serial)
        case .delete: showToast("Deleted “\(item.meta.title)”", serial: entry.serial)
        default: break
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// For Edit › Undo: "Undo Archive".
    var undoName: String? {
        switch undoStack.last?.change {
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .archive: "Archive"
        case .unarchive: "Unarchive"
        case .delete: "Delete Meeting"
        case nil: nil
        }
    }

    /// ⌘Z in the sidebar: the last pin, unpin, archive, unarchive or delete.
    @discardableResult
    func undoLast() -> Bool {
        guard let last = undoStack.last else { return false }
        undo(last)
        return true
    }

    func undo(_ entry: SidebarUndo) {
        undoStack.removeAll { $0.serial == entry.serial }
        if toast?.serial == entry.serial { hideToast() }
        if swipe.rowID == entry.id { swipe.reset() }
        switch entry.change {
        case .delete(let trashed, let folder):
            restore(entry, from: trashed, to: folder)
        case .pin, .unpin:
            put(entry, animation: Motion.reduceMotion ? nil : Motion.swipeSpring)
        case .archive, .unarchive:
            put(entry, animation: Motion.reduceMotion ? Motion.fade : Motion.appear)
        }
    }

    private func put(_ entry: SidebarUndo, animation: Animation?) {
        guard let item = item(entry.id) else { return }
        writeSidebarMeta(item, pinnedAt: entry.pinnedAt, archivedAt: entry.archivedAt, animation: animation)
        if entry.selected {
            showListed(entry.id)
            select(entry.id)
        }
    }

    /// The meeting undo selects again is listed: Archived when it is archived, all meetings when its group hides it.
    private func showListed(_ id: String) {
        guard !isSearching, let item = item(id), !listed.contains(where: { $0.id == id }) else { return }
        if item.isArchived {
            showingArchived = true
            groupFilter = nil
        } else {
            showingArchived = false
            if groupFilter != nil, groupID(of: item) != groupFilter { groupFilter = nil }
        }
    }

    /// Puts a deleted meeting's folder back where it was, and Sync sends it again.
    private func restore(_ entry: SidebarUndo, from trashed: URL, to folder: URL) {
        let parent = FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path)
            ? folder.deletingLastPathComponent() : Workspace.root
        let target = Workspace.uniqueURL(in: parent, name: folder.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: trashed, to: target)
        } catch {
            onError?(error)
            return
        }
        // Deleting may have sent the Drive copy to the Drive trash; the folder sync finds a missing copy itself.
        if let meta = Workspace.readMeta(target) { Sync.shared.meetingRestored(meta) }
        reload(preferring: entry.selected ? entry.id : nil)
        if entry.selected { showListed(entry.id) }
        Workspace.notifyChanged()
        onChanged?(entry.id)
    }

    private func showToast(_ text: String, serial: Int) {
        Motion.animate(Motion.appear) { toast = SidebarToast(serial: serial, text: text) }
        holdToast(false)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The pointer over the toast keeps it; leaving gives it the full time again.
    func holdToast(_ held: Bool) {
        toastTimer?.cancel()
        guard !held, let serial = toast?.serial else { return }
        let work = DispatchWorkItem { [weak self] in
            if self?.toast?.serial == serial { self?.hideToast() }
        }
        toastTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration, execute: work)
    }

    func hideToast() {
        toastTimer?.cancel()
        guard toast != nil else { return }
        Motion.animate(Motion.fade) { toast = nil }
    }

    func undoToast() {
        guard let serial = toast?.serial, let entry = undoStack.first(where: { $0.serial == serial }) else { return hideToast() }
        undo(entry)
    }

    /// Esc closes an open row. ⌘Z undoes the sidebar's last change from the list, or from anywhere while its toast is
    /// up and the text being typed has nothing of its own to undo. Matched by key position, for any keyboard layout.
    func sidebarKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, modifiers.isEmpty { return swipe.escape() }
        guard modifiers == .command, event.keyCode == 6, let last = undoStack.last else { return false }
        if let text = event.window?.firstResponder as? NSText {
            guard toast?.serial == last.serial, text.undoManager?.canUndo != true else { return false }
        }
        return undoLast()
    }

    enum SidebarCommand { case pin, archive, delete }

    /// The Meeting menu acts on a row swiped open, otherwise on the selected meeting.
    var menuTarget: String? {
        swipe.isOpen ? swipe.rowID : nil
    }

    /// The menu bar's Pin, Archive and Delete, for `id` or the selected meeting: its title and whether it applies.
    func command(_ command: SidebarCommand, for id: String? = nil) -> (title: String, enabled: Bool) {
        let item = (id ?? selectedID).flatMap(item)
        switch command {
        case .pin:
            return (item?.isPinned == true ? "Unpin" : "Pin", item.map { canPin($0.id) } ?? false)
        case .archive:
            return (item?.isArchived == true ? "Unarchive" : "Archive", item.map { $0.isArchived || canArchive($0.id) } ?? false)
        case .delete:
            return ("Delete Meeting…", item.map { canDelete($0.id) } ?? false)
        }
    }

    func perform(_ command: SidebarCommand, for id: String? = nil) {
        guard let item = (id ?? selectedID).flatMap(item), self.command(command, for: item.id).enabled else { return }
        switch command {
        case .pin: togglePin(item.id)
        case .archive: setArchived(item.id, !item.isArchived)
        case .delete: confirmDelete(store: self, item: item)
        }
    }

    // MARK: Groups

    @discardableResult
    func addGroup(named raw: String) -> MeetingGroup? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let group = MeetingGroup(id: UUID().uuidString, name: name)
        do {
            try Workspace.saveGroups(groups + [group])
            Motion.animate(populated ? Motion.move() : nil) { groups.append(group) }
            return group
        } catch {
            onError?(error)
            return nil
        }
    }

    func renameGroup(_ id: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }), groups[index].name != name else { return }
        var changed = groups
        changed[index].name = name
        do {
            try Workspace.saveGroups(changed)
            groups = changed
            // The Drive folder is named after the group.
            meetings.filter { $0.meta.groupID == id }.forEach { onChanged?($0.id) }
        } catch {
            onError?(error)
        }
    }

    /// The group goes; its meetings stay, without a group.
    func deleteGroup(_ id: String) {
        var failed: Error?
        for item in meetings where item.meta.groupID == id {
            do {
                try Workspace.updateMeta(item.folder) { $0.groupID = nil }
                onChanged?(item.id)
            } catch {
                failed = error
            }
        }
        for folder in stagedFolders.values where Workspace.readMeta(folder)?.groupID == id {
            _ = try? Workspace.updateMeta(folder) { $0.groupID = nil }
        }
        do {
            try Workspace.saveGroups(groups.filter { $0.id != id })
        } catch {
            failed = error
        }
        if groupFilter == id { groupFilter = nil }
        if editingGroup == id { editingGroup = nil }
        if let failed { onError?(failed) }
        reload()
    }

    /// "+": a group named "New Group", its name ready to be typed over. With a meeting, that meeting goes into it.
    @discardableResult
    func beginNewGroup(moving meetingID: String? = nil) -> MeetingGroup? {
        finishCurrentGroupEdit()
        // One transaction, so the row slides in already showing its name field.
        return Motion.animate(populated ? Motion.move() : nil) {
            guard let group = addGroup(named: "New Group") else { return nil }
            editingIsNew = true
            editingDraft = group.name
            editingGroup = group.id
            if let meetingID, let item = item(meetingID) {
                editingMoved = (meetingID, groupID(of: item))
                move(meetingID, to: group.id)
            }
            return group
        }
    }

    func beginRename(_ id: String) {
        guard editingGroup != id, let group = groups.first(where: { $0.id == id }) else { return }
        finishCurrentGroupEdit()
        editingIsNew = false
        editingDraft = group.name
        editingGroup = id
    }

    private func finishCurrentGroupEdit() {
        if let current = editingGroup { finishGroupEdit(current, name: editingDraft) }
    }

    /// Return or clicking away; an empty name keeps the one it had.
    func finishGroupEdit(_ id: String, name: String) {
        guard editingGroup == id else { return }
        editingGroup = nil
        editingMoved = nil
        renameGroup(id, to: name)
    }

    /// Esc: a group made with "+" goes away again, and a meeting put in it goes back where it was; a rename keeps the
    /// old name.
    func cancelGroupEdit(_ id: String) {
        guard editingGroup == id else { return }
        editingGroup = nil
        let moved = editingMoved
        editingMoved = nil
        guard editingIsNew else { return }
        if let moved { move(moved.meetingID, to: moved.from) }
        deleteGroup(id)
    }

    /// A group's new place in groups.json. Returns false when it is already there.
    @discardableResult
    func moveGroup(_ id: String, to index: Int) -> Bool {
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return false }
        var changed = groups
        let group = changed.remove(at: from)
        changed.insert(group, at: min(max(index, 0), changed.count))
        guard changed != groups else { return false }
        do {
            try Workspace.saveGroups(changed)
            Motion.animate(populated ? Motion.move() : nil) { groups = changed }
            return true
        } catch {
            onError?(error)
            return false
        }
    }

    /// A meeting dropped on a group row, or on All meetings (nil) to leave its group. False when it is already there.
    @discardableResult
    func dropMeeting(_ meetingID: String, on groupID: String?) -> Bool {
        guard let item = item(meetingID), self.groupID(of: item) != groupID else { return false }
        move(meetingID, to: groupID)
        return true
    }

    func move(_ meetingID: String, to groupID: String?) {
        guard let item = item(meetingID), item.meta.groupID != groupID else { return }
        do {
            try Workspace.updateMeta(item.folder) { $0.groupID = groupID }
            if !isStaged(item.id) { onChanged?(meetingID) }
            // Staged meetings are not part of the list key, so their count change is animated here.
            Motion.animate(populated ? Motion.move() : nil) { reload() }
        } catch {
            onError?(error)
        }
    }

    func syncModel() {
        if model != SummaryModel.current { model = SummaryModel.current }
    }

    func isBusy(_ id: String?) -> Bool {
        id.map(busy.contains) ?? false
    }

    func summarise(with choice: SummaryModel? = nil) {
        if let choice { SummaryModel.current = choice }
        syncModel()
        guard let id = selectedID, !busy.contains(id), let onSummarise else { return }
        // Marked now so a second click cannot start another job before the caller's setBusy arrives.
        busy.insert(id)
        onSummarise(id, model)
    }

    /// "Summarise anyway": the meeting stops being confidential, then is summarised.
    func summariseConfidential() {
        guard let id = selectedID else { return }
        setConfidential(false, for: id)
        summarise()
    }

    func setBusy(_ id: String, _ isBusy: Bool) {
        if isBusy {
            busy.insert(id)
        } else {
            busy.remove(id)
            if isOpen { reload() }
        }
    }

    func saveNotes() {
        notes.save()
    }

    // MARK: Pictures

    private let captureQueue = DispatchQueue(label: "Minutes.capture", qos: .userInitiated)

    /// The video's current frame into frames/, and a line for it in notes.md after the caret's line (or at the end).
    func capture() {
        guard case .video(let video) = player.source, let id = selectedID, let folder = item(id)?.folder else { return }
        let time = player.time
        captures += 1
        comments.side = .notes
        showAside()
        captureQueue.async { [weak self] in
            let result = Result { try Frames.capture(video: video, at: time, into: folder) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let path): self.notes.append("![\(MeetingFormat.longClock(time))](\(path))", to: id)
                case .failure(let error): self.onError?(error)
                }
            }
        }
    }

    func open(_ picture: PictureLook) {
        Motion.animate(Motion.reduceMotion ? Motion.fade : Motion.appear) { look = picture }
    }

    func closePicture() {
        Motion.animate(Motion.fade) { look = nil }
    }

    /// From the larger view: plays from the picture's time and closes it.
    func play(_ picture: PictureLook) {
        guard let time = picture.time else { return }
        player.seek(to: time, play: true)
        closePicture()
    }
}

/// The selected meeting's notes.md, saved a second after the last edit.
final class NotesDocument: ObservableObject {
    /// The notes as Markdown. While typing, made from the editor only when something needs it, such as the save.
    var text: String {
        if let typed {
            self.typed = nil
            current = typed() ?? current
        }
        return current
    }
    /// Counts loads and appends: the changes the editor has to show. Typing changes nothing here.
    @Published private(set) var revision = 0
    private var current = ""
    private var typed: (() -> String?)?
    /// notes.md exists for this meeting.
    @Published private(set) var onDisk = false
    private(set) var meetingID: String?
    private var saved = ""
    private var pendingSave: DispatchWorkItem?

    /// The page has a video, so pictures can play from their time.
    @Published var canPlay = false
    /// The picture line Capture just added, for the editor to reveal.
    var fresh: String?
    /// The editor showing these notes puts a Capture picture after the caret's line; false when it cannot.
    var insertPicture: ((String) -> Bool)?

    /// Looked up at save time, since a rename moves the folder.
    var folder: (String) -> URL? = { _ in nil }
    var onSaved: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    var play: (TimeInterval) -> Void = { _ in }
    var open: (PictureLook) -> Void = { _ in }

    func load(_ id: String?) {
        if meetingID != id { cleanAttachments() }
        meetingID = id
        let file = id.flatMap(folder)?.appendingPathComponent("notes.md")
        let value = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        onDisk = file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        typed = nil
        current = value
        saved = value
        revision += 1
    }

    func edit(_ value: String) {
        guard value != text else { return }
        current = value
        scheduleSave()
    }

    /// The editor changed; its Markdown is made later, when it is needed.
    func edit(lazy markdown: @escaping () -> String?) {
        typed = markdown
        scheduleSave()
    }

    /// The editor is going away: its text is taken now.
    func flush() {
        _ = text
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: save)
    }

    /// Adds `line` to the meeting's notes, after the caret's line when the editor shows them, and saves straight away.
    func append(_ line: String, to id: String) {
        let joined = { (text: String) in text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + line + "\n" }
        if id == meetingID, insertPicture?(line) == true {
            save()
            return
        }
        if id == meetingID {
            fresh = line
            current = joined(text)
            revision += 1
            save()
            return
        }
        guard let url = folder(id)?.appendingPathComponent("notes.md") else { return }
        do {
            try joined((try? String(contentsOf: url, encoding: .utf8)) ?? "").write(to: url, atomically: true, encoding: .utf8)
            onSaved?(id)
        } catch {
            onError?(error)
        }
    }

    /// Once these notes are put away (another meeting, the window closed) and undo can no longer bring a picture
    /// back: attachments notes.md no longer links to are deleted.
    func cleanAttachments() {
        save()
        guard let id = meetingID, text == saved, let folder = folder(id) else { return }
        let removed = NotesAttachments.clean(folder, keeping: saved)
        // The user took them out: copies in the synced folder or on Drive go too.
        if !removed.isEmpty { Sync.shared.deleteCopies(meetingID: id, names: removed) }
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let id = meetingID, text != saved, let folder = folder(id) else { return }
        let url = folder.appendingPathComponent("notes.md")
        if text.isEmpty, !FileManager.default.fileExists(atPath: url.path) {
            saved = text
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            saved = text
            onDisk = true
            onSaved?(id)
        } catch {
            onError?(error)
        }
    }
}

/// One player at a time: the selected meeting's video, or both audio tracks mixed when there is no video.
final class MediaPlayer: ObservableObject {
    enum Source: Equatable {
        case none
        case video(URL)
        case audio([URL])
    }

    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var speed: Float = 1
    /// Where the picture starts in a video muxed before its head was filled: black before it otherwise.
    @Published private(set) var videoStart: TimeInterval = 0
    /// The first frame, shown while the playhead is before `videoStart`.
    @Published private(set) var poster: CGImage?
    private(set) var source = Source.none

    private var observer: Any?
    private var generation = 0
    /// A seek asked for before the player was made; done once it is.
    private var pendingSeek: (time: TimeInterval, play: Bool)?

    init() {
        OneSound.register(.meeting) { [weak self] in self?.pause() }
    }

    func pause() {
        // A seek waiting for the player must not start it later.
        pendingSeek?.play = false
        guard let player, isPlaying || player.timeControlStatus != .paused else { return }
        player.pause()
        isPlaying = false
    }

    /// `start` puts the playhead back where it was when the meeting was last shown.
    func load(_ source: Source, at start: TimeInterval = 0) {
        unload()
        self.source = source
        guard source != .none else { return }
        // Kept as the position until the player exists, so moving on before then does not lose it.
        if time != start { time = start }
        let generation = self.generation
        // The new page is laid out and drawn first; the player is made on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.generation else { return }
            switch source {
            case .none:
                return
            case .video(let url):
                attach(AVPlayerItem(url: url), generation: generation, start: start)
            case .audio(let urls):
                Task { @MainActor in
                    let composition = await Self.mix(urls)
                    self.attach(AVPlayerItem(asset: composition), generation: generation, start: start)
                }
            }
        }
    }

    func unload() {
        generation += 1
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        pendingSeek = nil
        source = .none
        // Each change redraws the page; unchanged values are left alone.
        if player != nil { player = nil }
        if isPlaying { isPlaying = false }
        if time != 0 { time = 0 }
        if duration != 0 { duration = 0 }
        if videoStart != 0 { videoStart = 0 }
        if poster != nil { poster = nil }
    }

    /// As with the briefing: nothing plays while recording, or the mic could pick it up.
    private var blocked: Bool { BriefingCenter.shared.recording }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            guard !blocked else { return }
            if duration > 0, time >= duration - 0.25 { player.seek(to: .zero) }
            OneSound.began(.meeting)
            player.play()
        }
        isPlaying.toggle()
    }

    func setSpeed(_ value: Float) {
        speed = value
        player?.defaultRate = value
        if isPlaying { player?.rate = value }
    }

    func seek(to seconds: TimeInterval, play: Bool = false) {
        guard let player else {
            if source != .none {
                pendingSeek = (seconds, play)
                time = seconds
            }
            return
        }
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play && !blocked {
            OneSound.began(.meeting)
            player.play()
            isPlaying = true
        }
    }

    private func attach(_ item: AVPlayerItem, generation: Int, start: TimeInterval) {
        guard generation == self.generation else { return }
        let player = AVPlayer(playerItem: item)
        player.defaultRate = speed
        let pending = pendingSeek
        pendingSeek = nil
        let start = pending?.time ?? start
        if start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            time = start
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self, weak player] time in
            guard let self, let player else { return }
            self.time = time.seconds
            var playing = player.timeControlStatus != .paused
            // Started from the video's own controls.
            if playing && self.blocked {
                player.pause()
                playing = false
            } else if playing && !self.isPlaying {
                OneSound.began(.meeting)
            }
            self.isPlaying = playing
        }
        self.player = player
        if pending?.play == true, !blocked {
            OneSound.began(.meeting)
            player.play()
            isPlaying = true
        }
        Task { @MainActor in
            guard let length = try? await item.asset.load(.duration), generation == self.generation else { return }
            self.duration = length.seconds.isFinite ? length.seconds : 0
        }
        if case .video = source {
            Task { @MainActor in
                let asset = item.asset
                let start = await Muxer.firstFrame(in: asset)
                guard start > 0, generation == self.generation else { return }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                let image = try? await generator.image(at: CMTime(seconds: start, preferredTimescale: 600)).image
                guard generation == self.generation else { return }
                self.poster = image
                self.videoStart = start
            }
        }
    }

    // Each track (WAV or FLAC) goes on its own composition track; AVPlayer mixes them.
    private static func mix(_ urls: [URL]) async -> AVMutableComposition {
        let composition = AVMutableComposition()
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration)
            else { continue }
            let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try? target?.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
        }
        return composition
    }
}

// MARK: Parsing and formatting

struct TranscriptLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let speaker: String
    var text: String

    /// Me and Others name a track, not a voice; Speaker N, and the names given to them, can be renamed.
    static func canRename(_ speaker: String) -> Bool {
        !["Me", "Others"].contains(speaker)
    }
}

/// Reads transcript.md as written by Transcriber: a header, then one `**[hh:mm:ss] Speaker:** text` paragraph per turn.
enum TranscriptParser {
    static func parse(_ markdown: String) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        for row in markdown.components(separatedBy: .newlines) {
            let row = row.trimmingCharacters(in: .whitespaces)
            if let line = turn(row, id: lines.count) {
                lines.append(line)
            } else if !row.isEmpty, !lines.isEmpty {
                lines[lines.count - 1].text += " " + row
            }
        }
        return lines
    }

    /// Changes only the turn markers, so the same words inside the spoken text stay as they are.
    static func renaming(_ speaker: String, to name: String, in markdown: String) -> String {
        let pattern = #"^(\*\*\[\d+:\d\d:\d\d\] )"# + NSRegularExpression.escapedPattern(for: speaker) + #"(:\*\*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return markdown }
        let template = "$1" + NSRegularExpression.escapedTemplate(for: name) + "$2"
        return regex.stringByReplacingMatches(
            in: markdown, range: NSRange(markdown.startIndex..., in: markdown), withTemplate: template)
    }

    private static func turn(_ row: String, id: Int) -> TranscriptLine? {
        guard row.hasPrefix("**["),
              let close = row.range(of: "] "),
              let end = row.range(of: ":** ", range: close.upperBound..<row.endIndex) ?? row.range(of: ":**", range: close.upperBound..<row.endIndex)
        else { return nil }
        let stamp = row[row.index(row.startIndex, offsetBy: 3)..<close.lowerBound].split(separator: ":").compactMap { Double($0) }
        guard stamp.count == 3 else { return nil }
        return TranscriptLine(
            id: id,
            time: stamp[0] * 3600 + stamp[1] * 60 + stamp[2],
            speaker: String(row[close.upperBound..<end.lowerBound]),
            text: String(row[end.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
}

enum SummaryBlock: Equatable {
    case heading(String)
    case paragraph(String)
    case bullet(String, level: Int)
    case table(header: [String], rows: [[String]])
    /// A picture from frames/, under the paragraph or bullet before it.
    case picture(path: String)
}

/// The markdown subset the summary prompt produces: headings, bullets, paragraphs, pipe tables and pictures.
enum SummaryMarkdown {
    static func parse(_ markdown: String) -> [SummaryBlock] {
        var blocks: [SummaryBlock] = []
        var paragraph: [String] = []
        var table: [[String]] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
            if let header = table.first {
                let rows = table.dropFirst().map { row in Array((row + Array(repeating: "", count: header.count)).prefix(header.count)) }
                blocks.append(.table(header: header, rows: rows))
            }
            table = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            var row = raw.trimmingCharacters(in: .whitespaces)
            // Pictures go below the text they were written with, as blocks of their own.
            let pictures = row.hasPrefix("|") ? [] : Frames.links(in: row)
            defer {
                if !pictures.isEmpty {
                    flush()
                    blocks += pictures.map { .picture(path: $0.path) }
                }
            }
            if !pictures.isEmpty {
                for link in pictures.reversed() { row.removeSubrange(link.range) }
                row = row.trimmingCharacters(in: .whitespaces)
                if row == "-" || row == "*" { row = "" }
            }
            if row.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                if !isSeparator(row) { table.append(cells(row)) }
                continue
            }
            if !table.isEmpty { flush() }
            if row.isEmpty {
                flush()
            } else if row.hasPrefix("# ") {
                flush()
            } else if row.hasPrefix("#") {
                flush()
                blocks.append(.heading(row.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if blocks.isEmpty, paragraph.isEmpty, row.contains(" · Summarised by ") {
                // Summarizer's stamp line under the title; the tab header already says this.
                continue
            } else if row.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                flush()
                blocks.append(.paragraph(row))
            } else if row.hasPrefix("- ") || row.hasPrefix("* ") {
                flush()
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
                blocks.append(.bullet(String(row.dropFirst(2)), level: indent / 2))
            } else {
                paragraph.append(row)
            }
        }
        flush()
        return blocks
    }

    private static func cells(_ row: String) -> [String] {
        var parts = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func isSeparator(_ row: String) -> Bool {
        row.allSatisfy { "|-: ".contains($0) } && row.contains("-")
    }
}

enum MeetingFormat {
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatter(sameYear ? "EEE d MMM" : "EEE d MMM yyyy", calendar: calendar).string(from: date)
    }

    static func groups(_ items: [MeetingItem], now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, label: String, items: [MeetingItem])] {
        var groups: [(day: Date, label: String, items: [MeetingItem])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.meta.startedAt)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((day, dayLabel(item.meta.startedAt, now: now, calendar: calendar), [item]))
            }
        }
        return groups
    }

    static func minutes(_ meta: MeetingMeta) -> Int? {
        meta.endedAt.map { Int(($0.timeIntervalSince(meta.startedAt) / 60).rounded()) }
    }

    /// `52 min`, `1 h 05 min`
    static func duration(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    static func duration(_ meta: MeetingMeta) -> String? {
        minutes(meta).map { duration(minutes: $0) }
    }

    /// `14:00`
    static func time(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    /// A pinned row's time: `14:00` today, `Yesterday`, `26 Oct`, `26 Oct 2025` in another year.
    static func pinnedTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatter(sameYear ? "d MMM" : "d MMM yyyy", calendar: calendar).string(from: date)
    }

    /// `28 Oct 2026, 14:52`
    static func stamp(_ date: Date) -> String {
        formatter("d MMM yyyy, HH:mm").string(from: date)
    }

    /// `Wed 28 Oct 2026 · 14:00–14:52 · 52 min · Google Meet`, ending like `doneLabel`.
    static func metaLine(_ meta: MeetingMeta) -> String {
        let clock = formatter("HH:mm")
        let span = clock.string(from: meta.startedAt) + (meta.endedAt.map { "–" + clock.string(from: $0) } ?? "")
        return [formatter("EEE d MMM yyyy").string(from: meta.startedAt), span, duration(meta), metaTail(meta)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A finished meeting's row: `52 min · Google Meet` for a Screen recording, `38 min · Voice` with no app, and
    /// `24 min · Zoom · Voice` when an app's card started it in Voice.
    static func doneLabel(_ meta: MeetingMeta) -> String {
        [duration(meta), metaTail(meta)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The row's second line once nothing is happening to the meeting: `Note` for a note, else `doneLabel`.
    static func rowLabel(_ item: MeetingItem) -> String {
        item.isNote ? "Note" : doneLabel(item.meta)
    }

    /// `Wed 28 Oct 2026 · 16:20 · Note`
    static func noteLine(_ meta: MeetingMeta) -> String {
        [formatter("EEE d MMM yyyy").string(from: meta.startedAt), time(meta.startedAt), "Note"].joined(separator: " · ")
    }

    /// The app, then "Voice" for that mode; nil for a Screen recording of no app.
    static func metaTail(_ meta: MeetingMeta) -> String? {
        let parts = [meta.app, meta.recordMode == .voice ? RecordMode.voice.name : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `Wed 28 Oct 2026 · started 16:10 · Microsoft Teams`
    static func liveMetaLine(_ meta: MeetingMeta) -> String {
        [formatter("EEE d MMM yyyy").string(from: meta.startedAt), "started " + time(meta.startedAt), meta.app]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A note's page: the editor itself, with nothing happening to the folder.
    static func isNotePage(_ page: MeetingPage, state: NotesStore.PageState) -> Bool {
        if case .done = state { return page.item.isNote }
        return false
    }

    /// The line under the page title and the part of it that is the app. A recording into a note is not staged (the
    /// workspace holds the folder), so "live" follows the state, not `staged`.
    static func pageLine(_ page: MeetingPage, state: NotesStore.PageState) -> (line: String, tail: String?) {
        let meta = page.item.meta
        if isNotePage(page, state: state) { return (noteLine(meta), nil) }
        if case .done = state, !page.staged { return (metaLine(meta), metaTail(meta)) }
        return (liveMetaLine(meta), meta.app)
    }

    /// `at 14:55` on the day of the meeting, `on 29 Oct at 09:10` after it.
    static func when(_ date: Date, since start: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: start) ? "at " + time(date) : "on \(formatter("d MMM").string(from: date)) at \(time(date))"
    }

    /// `[00:12:34]` or `00:12:34` to seconds.
    static func seconds(fromStamp stamp: String) -> TimeInterval? {
        let parts = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":")
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == 3 else { return nil }
        return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
    }

    /// `00:12:34`, as the transcript writes it.
    static func longClock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite ? max(seconds, 0) : 0)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite ? max(seconds, 0) : 0)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ format: String, calendar: Calendar = .current) -> DateFormatter {
        let key = format + calendar.timeZone.identifier
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        // A Thai system calendar would otherwise print Buddhist-era years.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        formatters[key] = formatter
        return formatter
    }
}
