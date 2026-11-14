import AVFoundation
import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case recording, summary, storage, sync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: "Recording"
        case .summary: "Summary"
        case .storage: "Storage"
        case .sync: "Sync"
        }
    }

    var symbol: String {
        switch self {
        case .recording: "mic"
        case .summary: "doc.text"
        case .storage: "folder"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}

/// Minutes ▸ Settings…: one pane at a time under a toolbar of panes, every control applied as it changes.
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindowController()
    static let width: CGFloat = 760

    private(set) lazy var model = SettingsModel()
    private var window: NSWindow?
    private var hosting: NSHostingController<SettingsRootView>?
    private var changes: AnyCancellable?
    private var outgoing: NSView?

    @objc func showSettings() {
        show()
    }

    func show(pane: SettingsPane? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        if let pane { select(pane) }
        model.refresh()
        // Opening never animates the height; changes after that do.
        if !window.isVisible { fit(window, animate: false) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Models, Drive and the workspace changed elsewhere; only does work while the window is open.
    func refresh() {
        guard window?.isVisible == true else { return }
        model.refresh()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        configure(window)
        window.animationBehavior = .documentWindow
        window.center()
        window.setFrameAutosaveName("Settings")
        return window
    }

    func configure(_ window: NSWindow) {
        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        hosting.sizingOptions = []
        self.hosting = hosting
        // Pinned to the top, so the pane stays put while the window's height animates under it.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 480))
        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.width, .minYMargin]
        container.addSubview(hosting.view)
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: "SettingsPanes")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        select(model.pane, in: window, animate: false)
        // Rows come and go (the model picker, apps in the list), so the height follows each change.
        // refresh() changes several values at once; one measurement covers them.
        changes = model.objectWillChange.debounce(for: .milliseconds(20), scheduler: RunLoop.main).sink { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.fit(window, animate: window.isVisible)
        }
    }

    private func select(_ pane: SettingsPane) {
        guard let window else { return }
        select(pane, in: window, animate: window.isVisible)
    }

    /// The pane crossfades while the window's height follows; the title changes with it.
    func select(_ pane: SettingsPane, in window: NSWindow, animate: Bool) {
        if animate && model.pane != pane {
            crossfade(in: window) { model.pane = pane }
        } else {
            model.pane = pane
        }
        model.saveSelection()
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        window.title = pane.title
        fit(window, animate: animate)
    }

    /// A picture of the old pane, on the window's background, fades out over the new one.
    private func crossfade(in window: NSWindow, _ change: () -> Void) {
        guard let host = hosting?.view, let container = window.contentView,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return change() }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        outgoing?.removeFromSuperview()
        let old = NSImageView(frame: host.frame)
        old.image = image
        old.imageScaling = .scaleNone
        old.autoresizingMask = [.minYMargin]
        old.wantsLayer = true
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            old.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        container.addSubview(old)
        outgoing = old
        change()
        Motion.run(Motion.appearDuration, { _ in
            old.animator().alphaValue = 0
        }, completion: { [weak self] in
            old.removeFromSuperview()
            if self?.outgoing === old { self?.outgoing = nil }
        })
    }

    /// Height follows the pane; the top edge stays put.
    func fit(_ window: NSWindow, animate: Bool) {
        guard let hosting, let container = window.contentView else { return }
        // The view takes in the model's change before it is measured.
        hosting.view.layoutSubtreeIfNeeded()
        let height = ceil(hosting.sizeThatFits(in: NSSize(width: Self.width, height: 10_000)).height)
        let pinned = NSRect(x: 0, y: container.bounds.height - height, width: container.bounds.width, height: height)
        if hosting.view.frame != pinned { hosting.view.frame = pinned }
        guard abs(window.contentLayoutRect.height - height) > 0.5 else { return }
        let content = NSRect(x: 0, y: 0, width: Self.width, height: height)
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if animate && !Motion.reduceMotion {
            Motion.run(Motion.appearDuration) { _ in window.animator().setFrame(frame, display: true) }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    @objc private func pick(_ item: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: item.itemIdentifier.rawValue) else { return }
        select(pane)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(pick(_:))
        return item
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }
}

/// The Settings window's view of `Settings` and the services it shows; each setter writes through at once.
final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane

    // Recording
    @Published var askAnyApp = MeetingApps.askAnyApp { didSet { MeetingApps.askAnyApp = askAnyApp } }
    @Published private(set) var apps: [MeetingApps.App] = []
    @Published var selectedApp: String?
    @Published var autoStopSeconds = Settings.autoStopSeconds {
        didSet {
            let clamped = max(5, min(600, autoStopSeconds))
            if clamped != autoStopSeconds { autoStopSeconds = clamped; return }
            Settings.autoStopSeconds = clamped
        }
    }
    @Published var shortcut = Settings.recordShortcut
    @Published var shortcutTaken = false
    @Published var recordMode = Settings.recordMode { didSet { Settings.recordMode = recordMode } }
    @Published private(set) var screenAllowed = ScreenRecorder.hasPermission()
    @Published var videoQuality = Settings.videoQuality { didSet { Settings.videoQuality = videoQuality } }
    @Published var titleFromCalendar = Settings.titleFromCalendar {
        didSet {
            Settings.titleFromCalendar = titleFromCalendar
            if titleFromCalendar { Self.askForCalendar() }
        }
    }
    @Published var separateSpeakers = Settings.separateSpeakers {
        didSet {
            Settings.separateSpeakers = separateSpeakers
            if separateSpeakers && !ModelStore.missing.isEmpty { ModelStore.shared.start() }
            refreshModels()
        }
    }
    @Published var speechLanguage = Settings.speechLanguage { didSet { Settings.speechLanguage = speechLanguage } }
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    // Summary
    @Published var provider = Settings.summaryProvider {
        didSet {
            Settings.summaryProvider = provider
            if let engine = provider.engine { summaryModel = SummaryModel.chosen(engine) }
        }
    }
    @Published var summaryModel = SummaryModel.current { didSet { SummaryModel.remember(summaryModel) } }
    @Published private(set) var engines: [SummaryModel.Provider: EngineStatus] = [:]
    @Published private(set) var engineModels: [SummaryModel.Provider: [SummaryModel]] = [:]
    @Published var language = Settings.summaryLanguage { didSet { Settings.summaryLanguage = language } }
    @Published var autoSummarise = Settings.autoSummarise { didSet { Settings.autoSummarise = autoSummarise } }
    @Published var summaryPictures = Settings.summaryPictures { didSet { Settings.summaryPictures = summaryPictures } }
    @Published var confidentialExternal = Settings.confidentialExternal {
        didSet {
            Settings.confidentialExternal = confidentialExternal
            if confidentialExternal { Self.askForCalendar() }
        }
    }
    @Published private(set) var claude = ClaudeStatus.notFound
    @Published var briefingMode = Settings.briefingMode {
        didSet {
            BriefingCenter.shared.setMode(briefingMode)
            if briefingMode == .off { BriefingPreview.shared.stop() }
        }
    }
    @Published var briefingVoiceThai = Settings.briefingVoiceThai { didSet { Settings.briefingVoiceThai = briefingVoiceThai } }
    @Published var briefingVoiceEnglish = Settings.briefingVoiceEnglish {
        didSet { Settings.briefingVoiceEnglish = briefingVoiceEnglish }
    }
    @Published var briefingRate = Double(Settings.briefingRate) { didSet { Settings.briefingRate = Int(briefingRate.rounded()) } }
    /// Installed voices per language, best first; read again whenever the window comes forward.
    @Published private(set) var voices: [BriefingLanguage: [BriefingVoice]] = [:]

    // Storage
    @Published private(set) var workspacePath = Workspace.root.path
    @Published private(set) var usage: (bytes: Int64, meetings: Int)?
    @Published private(set) var cleanUpNote: String?
    @Published private(set) var cleaning = false
    @Published var keepVideoDays = Settings.keepVideoDays { didSet { Settings.keepVideoDays = keepVideoDays } }
    @Published var keepAudioDays = Settings.keepAudioDays { didSet { Settings.keepAudioDays = keepAudioDays } }
    @Published var compressAudio = Settings.compressAudio { didSet { Settings.compressAudio = compressAudio } }
    @Published private(set) var models: [ModelRow] = []

    let sync = SyncModel()

    enum ClaudeStatus { case signedIn, notSignedIn, notFound }

    struct EngineStatus: Equatable {
        let text: String
        let good: Bool
    }

    struct ModelRow: Identifiable {
        enum State: Equatable { case installed, missing, notNeeded, downloading(Int) }
        let id: String
        let label: String
        let name: String
        let state: State
    }

    private var usageGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var syncChanges: AnyCancellable?

    init() {
        pane = UserDefaults.standard.string(forKey: "settingsPane").flatMap(SettingsPane.init(rawValue:)) ?? .recording
        // The window's height follows the Sync pane's rows too.
        syncChanges = sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        observers.append(NotificationCenter.default.addObserver(forName: .meetingsChanged, object: nil, queue: .main) {
            [weak self] _ in self?.refreshUsage()
        })
        // A Record Screen or Record Voice menu item changes the default while the window is open.
        observers.append(NotificationCenter.default.addObserver(forName: .recordModeChanged, object: nil, queue: .main) {
            [weak self] _ in
            guard let self, self.recordMode != Settings.recordMode else { return }
            self.recordMode = Settings.recordMode
        })
        reloadApps()
        refreshModels()
        refreshVoices()
    }

    func saveSelection() {
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
    }

    /// Picks up anything changed outside the window: login item, Claude sign-in, models, sync, disk use.
    func refresh() {
        openAtLogin = SMAppService.mainApp.status == .enabled
        shortcutTaken = Hotkey.shared.isTaken
        screenAllowed = ScreenRecorder.hasPermission()
        claude = Self.claudeStatus()
        refreshEngines()
        workspacePath = Workspace.root.path
        reloadApps()
        refreshModels()
        sync.refresh()
        refreshUsage()
        refreshVoices()
    }

    // MARK: Audio briefing

    func refreshVoices() {
        let installed = [BriefingLanguage.thai, .english].reduce(into: [BriefingLanguage: [BriefingVoice]]()) {
            $0[$1] = BriefingVoices.installed($1)
        }
        if installed != voices { voices = installed }
    }

    /// The voice a briefing in `language` would use now: the saved one, or the best installed.
    func briefingVoice(_ language: BriefingLanguage) -> String? {
        let saved = language == .thai ? briefingVoiceThai : briefingVoiceEnglish
        let system = AVSpeechSynthesisVoice(language: language == .thai ? "th-TH" : "en-US")?.identifier
        return BriefingVoices.pick(saved: saved, from: voices[language] ?? [], language: language, systemDefault: system)?.id
    }

    func setBriefingVoice(_ id: String?, for language: BriefingLanguage) {
        if language == .thai { briefingVoiceThai = id } else { briefingVoiceEnglish = id }
    }

    /// The needed languages that have no Enhanced or Premium voice installed.
    var missingBetterVoices: [BriefingLanguage] {
        BriefingLanguage.needed(language).filter { !(voices[$0] ?? []).contains(where: \.better) }
    }

    static func openSpokenContent() {
        let pages = [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
        ]
        for page in pages {
            if let url = URL(string: page), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Recording

    func reloadApps() {
        apps = MeetingApps.listed()
        if let selectedApp, !apps.contains(where: { $0.bundleID == selectedApp }) { self.selectedApp = nil }
    }

    func isOn(_ app: MeetingApps.App) -> Bool { MeetingApps.isOn(app.bundleID) }

    func setOn(_ app: MeetingApps.App, _ on: Bool) {
        guard MeetingApps.isOn(app.bundleID) != on else { return }
        MeetingApps.toggle(app.bundleID)
        objectWillChange.send()
    }

    func alwaysRecords(_ app: MeetingApps.App) -> Bool { Settings.alwaysRecord.contains(app.bundleID) }

    func mode(of app: MeetingApps.App) -> RecordMode { Settings.mode(forApp: app.bundleID) }

    func setMode(_ mode: RecordMode, of app: MeetingApps.App) {
        Settings.setMode(mode, forApp: app.bundleID)
        objectWillChange.send()
    }

    func setAlwaysRecord(_ app: MeetingApps.App, _ always: Bool) {
        var list = Settings.alwaysRecord.filter { $0 != app.bundleID }
        if always { list.append(app.bundleID) }
        Settings.alwaysRecord = list
        objectWillChange.send()
    }

    /// Running apps with a Dock icon and apps seen or removed before, for "+".
    func addableApps() -> [MeetingApps.App] {
        let own = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != own }
            .map { MeetingApps.App(bundleID: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!) }
        return MeetingApps.addable(running: running, listed: apps)
    }

    func add(_ app: MeetingApps.App) {
        MeetingApps.add(app)
        reloadApps()
        selectedApp = app.bundleID
    }

    func removeSelected() {
        guard let selectedApp else { return }
        MeetingApps.remove(selectedApp)
        self.selectedApp = nil
        reloadApps()
    }

    func setShortcut(_ new: Shortcut) {
        shortcut = new
        Settings.recordShortcut = new
        shortcutTaken = Hotkey.shared.isTaken
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func askForCalendar() {
        switch CalendarTitle.status {
        case .notDetermined:
            CalendarTitle.requestAccess()
        case .fullAccess:
            break
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Summary

    func refreshEngines() {
        AgyEngine.refreshModels { [weak self] in self?.refreshEngines() }
        var models: [SummaryModel.Provider: [SummaryModel]] = [:]
        for engine in SummaryModel.Provider.allCases { models[engine] = SummaryModel.choices(engine) }
        engineModels = models
        let claudeText = switch claude {
        case .signedIn: "Signed in"
        case .notSignedIn: "Not signed in"
        case .notFound: "Not found"
        }
        let codex = CodexEngine.path() == nil ? EngineStatus(text: "Not found", good: false)
            : CodexEngine.signedIn() ? EngineStatus(text: "Signed in", good: true) : EngineStatus(text: "Not signed in", good: false)
        let agy = AgyEngine.path() == nil ? EngineStatus(text: "Not found", good: false)
            : AgyEngine.signedIn() ? EngineStatus(text: "Signed in", good: true) : EngineStatus(text: "Not signed in", good: false)
        let pulled = models[.ollama]?.count ?? 0
        let ollama = OllamaEngine.path() == nil ? EngineStatus(text: "Not found", good: false)
            : EngineStatus(text: pulled == 0 ? "No models" : pulled == 1 ? "1 model" : "\(pulled) models", good: pulled > 0)
        engines = [.claude: EngineStatus(text: claudeText, good: claude == .signedIn), .codex: codex, .agy: agy, .ollama: ollama]
        if let engine = provider.engine, summaryModel.provider != engine || !(models[engine] ?? []).contains(summaryModel) {
            let chosen = SummaryModel.chosen(engine)
            if chosen != summaryModel { summaryModel = chosen }
        }
    }

    /// "Signed in" needs the CLI and the account Claude Code keeps in ~/.claude.json after `claude` login.
    static func claudeStatus() -> ClaudeStatus {
        guard Summarizer.claudePath() != nil else { return .notFound }
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["oauthAccount"] is [String: Any]
        else { return .notSignedIn }
        return .signedIn
    }

    // MARK: Storage

    func chooseWorkspace(for window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = Workspace.root
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Workspace.root = url
            Workspace.notifyChanged()
            self?.workspacePath = url.path
            self?.refreshUsage()
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    func refreshUsage() {
        usageGeneration += 1
        let generation = usageGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = Housekeeping.usage()
            DispatchQueue.main.async {
                guard let self, generation == self.usageGeneration else { return }
                self.usage = usage
            }
        }
    }

    func cleanUpNow() {
        guard !cleaning else { return }
        cleaning = true
        cleanUpNote = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = Housekeeping.run()
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleaning = false
                self.cleanUpNote = Self.describe(report)
                self.refreshUsage()
            }
        }
    }

    static func describe(_ report: Housekeeping.Report) -> String {
        var parts: [String] = []
        if report.videosDeleted > 0 { parts.append(count(report.videosDeleted, "video")) }
        if report.audioDeleted > 0 { parts.append(count(report.audioDeleted, "audio track set", "audio track sets")) }
        guard !parts.isEmpty else { return "Nothing old enough to delete" }
        let freed = bytes(report.bytesFreed)
        return "Deleted \(parts.joined(separator: " and ")), \(freed) freed"
    }

    static func usageText(_ usage: (bytes: Int64, meetings: Int)) -> String {
        "\(bytes(usage.bytes)) in \(count(usage.meetings, "meeting"))"
    }

    /// "0 bytes" rather than the formatter's "Zero KB".
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    static func count(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }

    func refreshModels() {
        let all = ModelStore.all
        let percent: Int? = {
            if case .downloading(let p) = ModelStore.shared.state { return p }
            return nil
        }()
        func state(_ files: [ModelStore.Model], needed: Bool) -> ModelRow.State {
            if files.allSatisfy(\.isPresent) { return .installed }
            if !needed { return .notNeeded }
            return percent.map(ModelRow.State.downloading) ?? .missing
        }
        let speaker = all.filter { !$0.transcription }
        let speakerBytes = speaker.reduce(Int64(0)) { $0 + $1.size }
        let whisper = all.first { $0.file == Transcriber.model }
        let vad = all.first { $0.file == Transcriber.vadModel }
        models = [
            ModelRow(
                id: "speech", label: "Speech model",
                name: "large-v3-turbo q5_0 · " + ByteCountFormatter.string(fromByteCount: whisper?.size ?? 0, countStyle: .file),
                state: state(whisper.map { [$0] } ?? [], needed: true)),
            ModelRow(id: "vad", label: "Silence filter", name: "Silero VAD v5.1.2", state: state(vad.map { [$0] } ?? [], needed: true)),
            ModelRow(
                id: "speakers", label: "Speaker models",
                name: "pyannote 3.0 + CAM++ · " + ByteCountFormatter.string(fromByteCount: speakerBytes, countStyle: .file),
                state: state(speaker, needed: Settings.separateSpeakers)),
        ]
    }

    func downloadModels() {
        ModelStore.shared.start()
        refreshModels()
    }

    var modelError: String? {
        if case .failed(let message) = ModelStore.shared.state { return message }
        return nil
    }
}
