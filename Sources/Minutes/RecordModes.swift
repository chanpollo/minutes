import AppKit
import SwiftUI

/// What a recording captures, chosen before it starts and fixed until it stops.
enum RecordMode: String, CaseIterable, Codable {
    /// Mic, Mac audio and the meeting window.
    case screen
    /// Mic and Mac audio only, no screen. Started by hand with no call app, the mic may carry several people in the
    /// room, so its voices are told apart too; in a call the mic is the owner and stays Me.
    case voice

    /// A stored value, including the names the modes had before: "call" is Screen, "inPerson" is Voice. Settings are
    /// rewritten in the new form at the next launch (migrateRecordScreen), meta.json when it is next saved.
    init?(stored raw: String) {
        switch raw {
        case "call": self = .screen
        case "inPerson": self = .voice
        default: self.init(rawValue: raw)
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let mode = RecordMode(stored: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown record mode \(raw)"))
        }
        self = mode
    }

    var name: String {
        switch self {
        case .screen: "Screen"
        case .voice: "Voice"
        }
    }

    /// The menu item that starts this mode.
    var item: String {
        switch self {
        case .screen: "Record Screen"
        case .voice: "Record Voice"
        }
    }

    var recordsScreen: Bool { self == .screen }

    /// The live meters' labels for me.wav and others.wav.
    var meters: (me: String, others: String) {
        switch self {
        case .screen: ("Me", "Others")
        case .voice: ("Mic", "Mac audio")
        }
    }

    /// The Record? card's line about telling people.
    var cardDetail: String {
        switch self {
        case .screen: "Tell the other people the call is being recorded."
        case .voice: "Tell everyone you are recording."
        }
    }
}

extension Notification.Name {
    static let recordModeChanged = Notification.Name("MinutesRecordModeChanged")
}

extension Settings {
    static let recordModeKey = "recordMode"
    private static let appModesKey = "appModes"

    /// The mode ⌃⌥R and the window's Record button start in; every Record Screen / Record Voice menu item sets it.
    static var recordMode: RecordMode {
        get { UserDefaults.standard.string(forKey: recordModeKey).flatMap(RecordMode.init(stored:)) ?? .screen }
        set {
            guard newValue != recordMode else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: recordModeKey)
            NotificationCenter.default.post(name: .recordModeChanged, object: nil)
        }
    }

    /// The mode each app's Record? card starts at and Always record uses, by bundle ID.
    static var appModes: [String: RecordMode] {
        get { decodeModes(UserDefaults.standard.dictionary(forKey: appModesKey)) }
        set { UserDefaults.standard.set(newValue.mapValues(\.rawValue), forKey: appModesKey) }
    }

    static func mode(forApp bundleID: String?) -> RecordMode {
        bundleID.flatMap { appModes[$0] } ?? .screen
    }

    static func setMode(_ mode: RecordMode, forApp bundleID: String) {
        var modes = appModes
        modes[bundleID] = mode
        appModes = modes
    }

    private static func decodeModes(_ raw: [String: Any]?) -> [String: RecordMode] {
        (raw ?? [:]).compactMapValues { ($0 as? String).flatMap(RecordMode.init(stored:)) }
    }

    /// The Screen video switch became the mode: with it off, the default and every app the prompt was for record
    /// Voice. The old key goes either way.
    static func migrateRecordScreen(
        in defaults: UserDefaults = .standard,
        onlyTheseApps: () -> [String] = { MeetingApps.listed().map(\.bundleID).filter(MeetingApps.isOn) }
    ) {
        // The first names, call and inPerson, rewritten once so every reader sees the new ones: @AppStorage on the
        // window's Record button decodes with init(rawValue:), not init(stored:).
        if let raw = defaults.string(forKey: recordModeKey), RecordMode(rawValue: raw) == nil,
           let mode = RecordMode(stored: raw) {
            defaults.set(mode.rawValue, forKey: recordModeKey)
        }
        if let raw = defaults.dictionary(forKey: appModesKey),
           raw.values.contains(where: { ($0 as? String).map { RecordMode(rawValue: $0) == nil } ?? true }) {
            defaults.set(decodeModes(raw).mapValues(\.rawValue), forKey: appModesKey)
        }
        guard let screen = defaults.object(forKey: "recordScreen") as? Bool else { return }
        if !screen {
            defaults.set(RecordMode.voice.rawValue, forKey: recordModeKey)
            let apps = defaults.bool(forKey: "askAnyApp") ? Array(MeetingApps.known.keys) : onlyTheseApps()
            var modes = decodeModes(defaults.dictionary(forKey: appModesKey))
            for app in apps where modes[app] == nil { modes[app] = .voice }
            defaults.set(modes.mapValues(\.rawValue), forKey: appModesKey)
        }
        defaults.removeObject(forKey: "recordScreen")
    }
}

/// Where a recording was started from, which decides its mode and what that start saves.
enum RecordEntry: Equatable {
    /// ⌃⌥R.
    case shortcut
    /// A plain click on the window's Record button.
    case windowButton
    /// Record Screen or Record Voice in the menu bar, Dock or the window button's menu.
    case menu(RecordMode)
    /// Record on the Record? card, with the mode picked there.
    case card(RecordMode, bundleID: String?)
    /// Always record, without the card.
    case always(bundleID: String)

    /// Saves what this start sets (the default mode, or the app's mode) and returns the mode to record in.
    func apply() -> RecordMode {
        switch self {
        case .shortcut, .windowButton:
            return Settings.recordMode
        case .menu(let mode):
            Settings.recordMode = mode
            return mode
        case .card(let mode, let bundleID):
            if let bundleID { Settings.setMode(mode, forApp: bundleID) }
            return mode
        case .always(let bundleID):
            return Settings.mode(forApp: bundleID)
        }
    }
}

// MARK: What a mode records

/// One item of the "Mic · Mac audio · Screen" row.
struct RecordsItem: Equatable {
    enum Kind { case mic, audio, screen, noScreen }

    let kind: Kind
    let label: String
    /// Screen Recording is not allowed; the row offers Allow… where it can.
    var notAllowed = false

    var muted: Bool { kind == .noScreen }

    static func items(_ mode: RecordMode, screenAllowed: Bool = ScreenRecorder.hasPermission()) -> [RecordsItem] {
        var items = [RecordsItem(kind: .mic, label: "Mic"), RecordsItem(kind: .audio, label: "Mac audio")]
        if !mode.recordsScreen {
            items.append(RecordsItem(kind: .noScreen, label: "No screen"))
        } else if screenAllowed {
            items.append(RecordsItem(kind: .screen, label: "Screen"))
        } else {
            items.append(RecordsItem(kind: .noScreen, label: "Screen not allowed", notAllowed: true))
        }
        return items
    }

    var image: NSImage { image(textSize: 12) }

    /// A template glyph a little smaller than the text beside it; the crossed display has no SF Symbol of its own.
    func image(textSize: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: textSize - 1, weight: .regular)
        let name = switch kind {
        case .mic: "mic"
        case .audio: "speaker.wave.2"
        case .screen, .noScreen: "display"
        }
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        guard kind == .noScreen else { return symbol }
        let side = textSize + 2
        let size = NSSize(width: max(side, symbol.size.width), height: side)
        let crossed = NSImage(size: size, flipped: false) { rect in
            let glyph = NSRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                               width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: glyph)
            // Cut a gap either side of the slash, then draw it.
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 0.5))
            slash.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 0.5))
            NSGraphicsContext.current?.compositingOperation = .clear
            slash.lineWidth = 3.2
            slash.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            slash.lineWidth = 1.3
            slash.lineCapStyle = .round
            slash.stroke()
            return true
        }
        crossed.isTemplate = true
        return crossed
    }

    /// System Settings › Privacy & Security › Screen Recording.
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// "Mic · Mac audio · Screen" as the card, Settings and the recording page show it. Given a `width`, the screen item
/// moves to a second line when the row does not fit.
struct RecordsRow: View {
    let mode: RecordMode
    var screenAllowed = ScreenRecorder.hasPermission()
    /// Shows Allow… after "Screen not allowed".
    var offersAllow = false
    var width: CGFloat?
    /// 12 pt in Settings and on the recording page; the card uses 13.
    var textSize: CGFloat = 12

    var body: some View {
        let items = RecordsItem.items(mode, screenAllowed: screenAllowed)
        Group {
            if let width {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { ForEach(items, id: \.label, content: item) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) { ForEach(items.dropLast(), id: \.label, content: item) }
                        if let last = items.last { item(last) }
                    }
                }
                .frame(width: width, alignment: .leading)
            } else {
                HStack(spacing: 12) { ForEach(items, id: \.label, content: item) }
                    .fixedSize()
            }
        }
        .font(.system(size: textSize))
        .accessibilityElement(children: .combine)
    }

    private func item(_ item: RecordsItem) -> some View {
        let style = item.muted ? Color.secondary : Color.primary.opacity(0.78)
        return HStack(spacing: 5) {
            Image(nsImage: item.image(textSize: textSize))
                .renderingMode(.template)
                .foregroundStyle(style)
                .accessibilityHidden(true)
            Text(item.label)
                .foregroundStyle(style)
            if item.notAllowed && offersAllow {
                Button("Allow…", action: RecordsItem.openScreenRecordingSettings)
                    .buttonStyle(.link)
                    .help("Opens System Settings › Privacy & Security › Screen Recording")
            }
        }
        .fixedSize()
    }
}

extension Color {
    /// Filled Record and Stop buttons, the same red in both themes; dots and the menu bar glyph use `recordDot`.
    static let recordFill = Color(nsColor: .recordFill)
}

extension NSColor {
    static let recordFill = NSColor(srgbRed: 0xd7 / 255, green: 0, blue: 0x15 / 255, alpha: 1)
    static let recordDot = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemRed : .recordFill
    }
}
