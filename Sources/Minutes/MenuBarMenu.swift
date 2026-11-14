import AppKit
import SwiftUI

/// What the first line of the menu bar menu shows.
enum MenuBarStatus {
    case waiting(label: String, progress: Double? = nil, note: String? = nil)
    /// `label` is "<App> · <mode> · mm:ss"; `levels` is polled while the menu is open; `note` is a transcript being made
    /// meanwhile.
    case recording(label: String, mode: RecordMode = .screen, levels: () -> (me: Float, others: Float), note: String? = nil)
    case transcribing(label: String, progress: Double?, note: String?)
    /// "Briefing · <title>", the share played and "0:42 / 1:34"; the bar is in the accent colour.
    case briefing(label: String, progress: Double, note: String)
}

/// "Play Last Briefing" or "Pause Briefing"; nil hides it (Audio briefing is Off).
struct BriefingMenuEntry {
    var playing: Bool
    /// "Sprint review · 1:34"; nil when there is no briefing yet.
    var subtitle: String?
    var enabled: Bool
}

/// The menu under the menu bar icon. Settings live in the Settings window, not here.
final class MenuBarMenu: NSObject, NSMenuDelegate {
    struct Actions {
        var record: (RecordMode) -> Void = { _ in }
        var stop: () -> Void = {}
        var discard: () -> Void = {}
        var openNotes: () -> Void = {}
        var newNote: () -> Void = {}
        var openFolder: () -> Void = {}
        var settings: () -> Void = {}
        var about: () -> Void = {}
        var downloadModels: () -> Void = {}
        var playBriefing: () -> Void = {}
        var mute: () -> Void = {}
    }

    let menu = NSMenu()
    var actions = Actions()
    /// Read again 30 times a second while the menu is open, so the meters move smoothly.
    var status: () -> MenuBarStatus = { .waiting(label: "Waiting for a meeting") }

    private let line = MenuStatusLine()
    private lazy var lineView = NSHostingView(rootView: MenuStatusView(line: line))
    private var timer: Timer?
    /// The items that start or stop a recording, for the shortcut shown on one of them.
    private var recordItems: [NSMenuItem] = []
    private var recording = false

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func rebuild(
        recording: Bool, canDownloadModels: Bool, shortcut: Shortcut, mode: RecordMode = Settings.recordMode,
        briefing: BriefingMenuEntry? = nil, muted: Bool = false
    ) {
        menu.removeAllItems()
        update()
        let status = NSMenuItem()
        status.view = lineView
        menu.addItem(status)

        self.recording = recording
        line.muted = recording && muted
        recordItems = recording
            ? [item("Stop Recording", #selector(stopRecording))]
            : Self.startItems(target: self, action: #selector(record(_:)))
        showShortcut(shortcut, mode: mode)
        recordItems.forEach(menu.addItem)
        if recording {
            let mute = item("Mute Microphone", #selector(toggleMute))
            mute.state = muted ? .on : .off
            menu.addItem(mute)
            menu.addItem(item("Discard Recording…", #selector(discard)))
        }
        if canDownloadModels { menu.addItem(item("Download Speech Models…", #selector(downloadModels))) }

        menu.addItem(.separator())
        if let briefing {
            let play = item(briefing.playing ? "Pause Briefing" : "Play Last Briefing", #selector(playBriefing))
            play.isEnabled = briefing.enabled
            // NSMenuItem.subtitle arrived in macOS 14.4.
            if #available(macOS 14.4, *), !briefing.playing, let subtitle = briefing.subtitle { play.subtitle = subtitle }
            menu.addItem(play)
        }
        menu.addItem(item("New Note", #selector(newNote), key: "n"))
        menu.addItem(item("Open Minutes", #selector(openNotes), key: "o"))
        menu.addItem(item("Open Meetings Folder", #selector(openFolder)))
        menu.addItem(.separator())
        menu.addItem(item("About Minutes", #selector(openAbout)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(NSMenuItem(title: "Quit Minutes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Re-reads `status` into the first line; an open menu updates in place, its meters easing to the new values.
    func update() {
        apply(smooth: timer != nil)
    }

    private func apply(smooth: Bool) {
        guard line.apply(status(), smooth: smooth) else { return }
        let size = lineView.fittingSize
        if lineView.frame.size != size { lineView.setFrameSize(NSSize(width: MenuStatusView.width, height: size.height)) }
    }

    /// Record Screen and Record Voice; each starts at once in its mode.
    static func startItems(target: AnyObject, action: Selector) -> [NSMenuItem] {
        RecordMode.allCases.map { mode in
            let item = NSMenuItem(title: mode.item, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = mode.rawValue
            return item
        }
    }

    /// The shortcut goes on Stop Recording, else on the default mode's item.
    private func showShortcut(_ shortcut: Shortcut, mode: RecordMode) {
        for item in recordItems {
            let shows = recording || item.representedObject as? String == mode.rawValue
            item.keyEquivalent = shows ? shortcut.menuKeyEquivalent : ""
            item.keyEquivalentModifierMask = shows ? shortcut.modifiers : []
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        apply(smooth: false)
        // The shortcut or the default mode may have changed in Settings since the menu was built.
        showShortcut(Settings.recordShortcut, mode: Settings.recordMode)
        let timer = Timer(timeInterval: MenuStatusLine.tick, repeats: true) { [weak self] _ in self?.update() }
        // The menu tracks in its own run loop mode; .common includes it.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        timer?.invalidate()
        timer = nil
    }

    @objc private func record(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(RecordMode.init(rawValue:)) else { return }
        actions.record(mode)
    }
    @objc private func stopRecording() { actions.stop() }
    @objc private func discard() { actions.discard() }
    @objc private func openNotes() { actions.openNotes() }
    @objc private func newNote() { actions.newNote() }
    @objc private func openFolder() { actions.openFolder() }
    @objc private func openSettings() { actions.settings() }
    @objc private func openAbout() { actions.about() }
    @objc private func downloadModels() { actions.downloadModels() }
    @objc private func playBriefing() { actions.playBriefing() }
    @objc private func toggleMute() { actions.mute() }
}

final class MenuStatusLine: ObservableObject {
    static let tick: TimeInterval = 1.0 / 30
    /// Share of the way to the new value covered each tick: levels settle within 0.1 s, the bar within 0.2 s.
    static let levelStep = 0.6
    static let barStep = 0.35

    @Published var label = ""
    @Published var recording = false
    @Published var muted = false
    @Published var mode = RecordMode.screen
    @Published var me: Float = 0
    @Published var others: Float = 0
    @Published var showsBar = false
    @Published var accentBar = false
    @Published var progress: Double = 0
    @Published var note: String?

    /// Returns whether the line's shape changed (rows shown, label or note), which needs a new size.
    @discardableResult
    func apply(_ status: MenuBarStatus, smooth: Bool = false) -> Bool {
        switch status {
        case .waiting(let label, let progress, let note):
            return set(label: label, recording: false, bar: progress, note: note, smooth: smooth)
        case .recording(let label, let mode, let levels, let note):
            var changed = set(label: label, recording: true, bar: nil, note: note, smooth: smooth)
            if self.mode != mode { self.mode = mode; changed = true }
            let now = levels()
            let step = Float(smooth ? Self.levelStep : 1)
            let (me, others) = (Self.ease(self.me, to: now.me, step: step), Self.ease(self.others, to: now.others, step: step))
            if self.me != me { self.me = me }
            if self.others != others { self.others = others }
            return changed
        case .transcribing(let label, let progress, let note):
            return set(label: label, recording: false, bar: progress ?? 0, note: note, smooth: smooth)
        case .briefing(let label, let progress, let note):
            return set(label: label, recording: false, bar: progress, note: note, smooth: smooth, accent: true)
        }
    }

    private func set(label: String, recording: Bool, bar: Double?, note: String?, smooth: Bool, accent: Bool = false) -> Bool {
        var changed = false
        if accentBar != accent { accentBar = accent }
        if self.label != label { self.label = label; changed = true }
        if self.recording != recording { self.recording = recording; changed = true }
        if showsBar != (bar != nil) { showsBar = bar != nil; changed = true }
        if self.note != note { self.note = note; changed = true }
        // A bar that just appeared starts at its value; only later changes ease.
        if let bar {
            let next = Self.ease(progress, to: bar, step: smooth && !changed ? Self.barStep : 1)
            if progress != next { progress = next }
        }
        return changed
    }

    /// Moves part of the way and lands exactly once close enough, so an idle meter stops publishing.
    static func ease<T: BinaryFloatingPoint>(_ value: T, to target: T, step: T) -> T {
        let next = value + (target - value) * step
        return abs(target - next) < 0.002 ? target : next
    }
}

struct MenuStatusView: View {
    static let width: CGFloat = 268
    @ObservedObject var line: MenuStatusLine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if line.recording {
                    Circle().fill(Color.recording).frame(width: 7, height: 7)
                }
                Text(line.label).lineLimit(1).truncationMode(.middle).monospacedDigit()
            }
            .foregroundStyle(.secondary)
            if line.recording {
                let names = line.mode.meters
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text(line.muted ? "\(names.me) (muted)" : names.me).frame(minWidth: 60, alignment: .leading)
                        MenuMeter(value: Double(line.me))
                    }
                    GridRow {
                        Text(names.others).frame(minWidth: 60, alignment: .leading)
                        MenuMeter(value: Double(line.others))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Levels: \(names.me) \(Int(line.me * 100)) percent, \(names.others) \(Int(line.others * 100)) percent")
            }
            if line.showsBar {
                MenuMeter(value: line.progress, accent: line.accentBar)
                    .accessibilityLabel("\(Int(line.progress * 100)) percent")
            }
            if let note = line.note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).monospacedDigit()
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(width: Self.width, alignment: .leading)
    }
}

/// A thin bar: the track at low contrast, the filled part in the text colour.
private struct MenuMeter: View {
    let value: Double
    var accent = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(accent ? Color.accentColor : Color.primary.opacity(0.85))
                    .frame(width: max(0, min(1, value)) * geometry.size.width)
            }
        }
        .frame(height: 4)
    }
}
