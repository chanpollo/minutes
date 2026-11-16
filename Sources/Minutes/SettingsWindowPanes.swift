import AppKit
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch model.pane {
            case .recording: RecordingPane(model: model)
            case .summary: SummaryPane(model: model)
            case .storage: StoragePane(model: model)
            case .sync: SyncPane(model: model.sync)
            }
            VersionLine()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(width: SettingsWindowController.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Minutes 0.6.1 (10)" at the foot of every pane; a click opens About Minutes.
private struct VersionLine: View {
    var body: some View {
        Button(AppVersion.current.line) { VersionsWindowController.shared.show() }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("About Minutes")
    }
}

// MARK: Shared pieces

/// Right-aligned labels in a 200-point column, controls beside them.
private struct SettingsGrid<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: spacing) {
            content
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        GridRow {
            Text(label)
                .frame(width: 200, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            content
        }
    }
}

private struct Hint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small dot and word for a state that matters: green when ready, grey otherwise.
private struct StatusBadge: View {
    let text: String
    var good = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(good ? Color.statusGood : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(good ? Color.statusGood : Color.secondary)
        .fixedSize()
    }
}

private extension Color {
    /// #1e7b34 on light, the system green on dark: readable as text on either.
    static let statusGood = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen : NSColor(srgbRed: 0.118, green: 0.482, blue: 0.204, alpha: 1)
    })
}

private struct CodeText: View {
    let text: String

    var body: some View {
        Text(Self.shortened(text))
            .help(text)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            // 300 pt with its padding, so the button after it stays inside the column.
            .frame(maxWidth: 284, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            .fixedSize()
    }

    /// Long paths and client IDs keep both ends.
    static func shortened(_ text: String, limit: Int = 44) -> String {
        guard text.count > limit else { return text }
        let half = (limit - 1) / 2
        return text.prefix(half) + "…" + text.suffix(half)
    }
}

/// A control that turns on or off with another setting crossfades between its two looks.
private struct FadesEnabled: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content.disabled(!enabled).id(enabled).transition(.opacity)
    }
}

private extension View {
    func fadesEnabled(_ enabled: Bool) -> some View { modifier(FadesEnabled(enabled: enabled)) }
}

private extension Binding {
    /// Changes made through the control animate what depends on them.
    var animated: Binding { Motion.reduceMotion ? self : animation(Motion.appear) }
}

private struct Legend: View {
    let text: String

    var body: some View {
        Text(text).fontWeight(.semibold).padding(.bottom, 2)
    }
}

// MARK: Recording

private struct RecordingPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Legend(text: "Ask to record when")
            Picker("Ask to record when", selection: $model.askAnyApp.animated) {
                Text("Any app holds the microphone for 4 seconds").tag(true)
                Text("Only these apps use the microphone").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            AppList(model: model)
                .padding(.leading, 20)
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Legend(text: "Shortcut and Record button use")
            ForEach(RecordMode.allCases, id: \.self) { mode in
                ModeRow(mode: mode, chosen: model.recordMode == mode, screenAllowed: model.screenAllowed) {
                    model.recordMode = mode
                }
            }
            Hint(text: "\(model.shortcut.display) and the window's Record button start in this mode. "
                 + "Record Screen or Record Voice in a menu also sets it.")
                .padding(.top, 2)
        }

        Divider()

        SettingsGrid {
            SettingsRow(label: "Stop automatically") {
                HStack(spacing: 8) {
                    TextField("Seconds", value: $model.autoStopSeconds, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("seconds after the call releases the microphone")
                }
            }
            SettingsRow(label: "Start or stop") {
                HStack(spacing: 8) {
                    ShortcutField(model: model)
                    Hint(text: model.shortcutTaken ? "macOS refused this shortcut; choose another" : "works from any app")
                }
            }
            SettingsRow(label: "Call video") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Call video", selection: $model.videoQuality) {
                        Text("Smaller files").tag(Settings.VideoQuality.smaller)
                        Text("Balanced").tag(Settings.VideoQuality.balanced)
                        Text("Best quality").tag(Settings.VideoQuality.best)
                    }
                    .labelsHidden()
                    .frame(width: 260, alignment: .leading)
                    Hint(text: "Every setting keeps the window's full resolution; smaller files drop detail in fast motion first.")
                }
            }
            SettingsRow(label: "Meeting title") {
                Toggle("Use the calendar event that is on now", isOn: $model.titleFromCalendar)
            }
            SettingsRow(label: "Speakers") {
                Toggle("Tell voices apart (Speaker 1, 2…)", isOn: $model.separateSpeakers)
            }
            SettingsRow(label: "Spoken language") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Spoken language", selection: $model.speechLanguage) {
                        Text("Thai").tag(Settings.SpeechLanguage.thai)
                        Text("English").tag(Settings.SpeechLanguage.english)
                        Text("Detect automatically").tag(Settings.SpeechLanguage.detect)
                    }
                    .labelsHidden()
                    .frame(width: 260, alignment: .leading)
                    Hint(text: "Detect picks the wrong language on quiet or mixed audio; choose the meeting's language when you can.")
                }
            }
            SettingsRow(label: "At login") {
                Toggle("Open Minutes", isOn: Binding(get: { model.openAtLogin }, set: model.setOpenAtLogin))
            }
        }
    }
}

/// One choice of the default mode: a radio, the mode's name and what it records; the chosen row is outlined.
private struct ModeRow: View {
    let mode: RecordMode
    let chosen: Bool
    let screenAllowed: Bool
    let pick: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            Text(mode.name)
                .fontWeight(.medium)
                .frame(width: 70, alignment: .leading)
            RecordsRow(mode: mode, screenAllowed: screenAllowed, offersAllow: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(chosen ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(chosen ? Color.accentColor : Color(nsColor: .separatorColor)))
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, pick)
    }
}

/// The apps that bring up the prompt: a bordered list with + and − under it, as in macOS's own settings. Each app
/// keeps its mode and Always record under either choice; the tick boxes only count with "Only these apps".
private struct AppList: View {
    @ObservedObject var model: SettingsModel
    private let rowHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.apps, id: \.bundleID) { app in
                        row(app)
                    }
                }
            }
            .frame(height: rowHeight * CGFloat(min(max(model.apps.count, 3), 6)))
            Divider()
            HStack(spacing: 0) {
                Menu {
                    let addable = model.addableApps()
                    if addable.isEmpty {
                        Text("No other apps are open")
                    }
                    ForEach(addable, id: \.bundleID) { app in
                        Button(app.name) { model.add(app) }
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add an app")
                Divider().frame(height: 16)
                Button {
                    model.removeSelected()
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedApp == nil)
                .help("Remove the selected app")
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .frame(width: 420)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row(_ app: MeetingApps.App) -> some View {
        let selected = model.selectedApp == app.bundleID
        return HStack(spacing: 10) {
            Toggle(app.name, isOn: Binding(get: { model.isOn(app) }, set: { model.setOn(app, $0) }))
                .lineLimit(1)
                .disabled(model.askAnyApp)
                .opacity(model.askAnyApp ? 0.5 : 1)
            Spacer(minLength: 8)
            Toggle("Always record", isOn: Binding(get: { model.alwaysRecords(app) }, set: { model.setAlwaysRecord(app, $0) }))
                .font(.system(size: 12))
                .fixedSize()
            Picker("Mode for \(app.name)", selection: Binding(get: { model.mode(of: app) }, set: { model.setMode($0, of: app) })) {
                ForEach(RecordMode.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 104)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        .background(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedApp = app.bundleID }
        .contextMenu {
            Button("Remove") {
                model.selectedApp = app.bundleID
                model.removeSelected()
            }
        }
    }
}

/// Shows the shortcut; click, then press the new keys. Escape keeps the old one.
private struct ShortcutField: View {
    @ObservedObject var model: SettingsModel
    @State private var listening = false
    @State private var monitor: Any?
    @State private var observers: [NSObjectProtocol] = []

    var body: some View {
        Button {
            listening ? stop() : start()
        } label: {
            Text(listening ? "Type shortcut" : model.shortcut.display)
                .monospacedDigit()
                .frame(minWidth: 80)
        }
        .onDisappear(perform: stop)
        .help("Click, then press the keys you want")
    }

    private func start() {
        guard let window = NSApp.keyWindow else { return }
        listening = true
        Hotkey.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Typing in any other window goes on as usual.
            guard event.window === window else { return event }
            if event.keyCode == 53 {
                stop()
            } else if let shortcut = Shortcut(event: event) {
                model.setShortcut(shortcut)
                stop()
            }
            return nil
        }
        // Leaving the window ends listening, so the old shortcut works again.
        observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { _ in stop() }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if listening { Hotkey.shared.resume() }
        listening = false
    }
}

// MARK: Summary

private struct SummaryPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Legend(text: "Summarise with")
            card(.claude, name: "Claude Code", detail: "Uses your Claude subscription through claude -p")
            card(.codex, name: "Codex", detail: "Uses your ChatGPT subscription through codex exec")
            card(.agy, name: "Antigravity", detail: "Uses Gemini on your Google sign-in through agy -p")
            card(.ollama, name: "Ollama", detail: "Runs a model you pulled on this Mac. Nothing is sent.")
            ProviderCard(
                name: "Off", detail: "Transcript only. Nothing is sent for a summary.",
                status: nil, good: false, selected: model.provider == .off
            ) { Motion.animate(Motion.settle) { model.provider = .off } }
            if let engine = model.provider.engine, let choices = model.engineModels[engine], !choices.isEmpty {
                HStack(spacing: 10) {
                    Text("Model").font(.system(size: 12))
                    Picker("Model", selection: $model.summaryModel) {
                        ForEach(choices, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.leading, 34)
                .padding(.top, 4)
                .transition(.opacity)
            }
        }

        Divider()

        SettingsGrid {
            SettingsRow(label: "Summary language") {
                Picker("Summary language", selection: $model.language) {
                    Text("Thai").tag(Settings.SummaryLanguage.thai)
                    Text("English").tag(Settings.SummaryLanguage.english)
                    Text("Same as the meeting").tag(Settings.SummaryLanguage.meeting)
                }
                .labelsHidden()
                .fixedSize()
                .fadesEnabled(model.provider != .off)
            }
            SettingsRow(label: "When") {
                Toggle("Summarise automatically when the transcript is ready", isOn: $model.autoSummarise)
                    .fadesEnabled(model.provider != .off)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Mark meetings with external attendees as confidential", isOn: $model.confidentialExternal)
            }
            SettingsRow(label: "Pictures") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Add pictures from the video", isOn: $model.summaryPictures)
                        .disabled(model.provider == .off)
                    Hint(text: "Slides and shared screens, placed under the point they show. Their text is read on this Mac and sent with the transcript.")
                        .opacity(model.provider == .off ? 0.45 : 1)
                }
            }
        }

        Divider()

        BriefingSettings(model: model)
    }

    private func card(_ engine: SummaryModel.Provider, name: String, detail: String) -> some View {
        let status = model.engines[engine]
        let selected = model.provider.engine == engine
        return ProviderCard(
            name: name, detail: detail, status: status?.text, good: status?.good ?? false, selected: selected,
            signIn: status?.canSignIn == true ? { SettingsModel.signIn(engine) } : nil
        ) {
            Motion.animate(Motion.settle) { model.provider = Settings.SummaryProvider(engine) }
        }
    }
}

/// Audio briefing: when it is made, the voice for each summary language, the rate, and where better voices come from.
private struct BriefingSettings: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var preview = BriefingPreview.shared

    var body: some View {
        let on = model.briefingMode != .off
        SettingsGrid {
            SettingsRow(label: "Audio briefing") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Audio briefing", selection: $model.briefingMode.animated) {
                        Text("Off").tag(Settings.BriefingMode.off)
                        Text("On request").tag(Settings.BriefingMode.request)
                        Text("After every summary").tag(Settings.BriefingMode.after)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Hint(text: "The script is written by the summary model. The voice is made on this Mac and the audio is never uploaded.")
                }
            }
            let languages = BriefingLanguage.needed(model.language)
            ForEach(languages, id: \.self) { language in
                GridRow {
                    Text(languages.count > 1 ? "\(language.name) voice" : "Voice")
                        .frame(width: 200, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                        .dimmed(!on)
                    voiceRow(language).dimmed(!on)
                }
            }
            GridRow {
                Text("Speaking rate")
                    .frame(width: 200, alignment: .trailing)
                    .gridColumnAlignment(.trailing)
                    .dimmed(!on)
                HStack(spacing: 10) {
                    Text("Slower").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: $model.briefingRate, in: 0...4, step: 1) { Text("Speaking rate") }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityValue(["Slowest", "Slower", "Normal", "Faster", "Fastest"][Int(model.briefingRate.rounded())])
                    Text("Faster").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .dimmed(!on)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                VStack(alignment: .leading, spacing: 4) {
                    Button("Get Better Voices…") { SettingsModel.openSpokenContent() }
                        .help("Opens System Settings › Accessibility › Spoken Content")
                    let missing = model.missingBetterVoices
                    if !missing.isEmpty {
                        Hint(text: "No Enhanced or Premium \(missing.map(\.name).joined(separator: " or ")) voice is installed.")
                    }
                }
                .dimmed(!on)
            }
        }
    }

    private func voiceRow(_ language: BriefingLanguage) -> some View {
        let voices = model.voices[language] ?? []
        let labels = BriefingVoices.labels(voices)
        let selected = model.briefingVoice(language)
        let previewing = preview.speaking == language
        return HStack(spacing: 8) {
            Picker("\(language.name) voice", selection: Binding(get: { selected ?? "" }, set: { model.setBriefingVoice($0, for: language) })) {
                if voices.isEmpty { Text("None installed").tag("") }
                ForEach(voices) { Text(labels[$0.id] ?? $0.label).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                preview.toggle(language, voice: selected, rate: Int(model.briefingRate.rounded()))
            } label: {
                Label(previewing ? "Stop" : "Preview", systemImage: previewing ? "stop.fill" : "play.fill")
            }
            .disabled(voices.isEmpty || preview.blocked)
            .help(preview.blocked ? "Not while recording" : "Hear this voice at the speaking rate")
            .accessibilityLabel(previewing ? "Stop preview" : "Preview \(selected.flatMap { labels[$0] } ?? language.name)")
        }
    }
}

private extension View {
    /// Rows that only matter while Audio briefing is on fade to 0.45 and stop taking clicks when it is Off.
    func dimmed(_ off: Bool) -> some View {
        disabled(off).opacity(off ? 0.45 : 1)
    }
}

private struct ProviderCard: View {
    let name: String
    let detail: String
    let status: String?
    let good: Bool
    let selected: Bool
    var signIn: (() -> Void)? = nil
    let pick: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let status {
                VStack(alignment: .trailing, spacing: 6) {
                    StatusBadge(text: status, good: good)
                    if let signIn {
                        Button("Sign In…", action: signIn)
                            .controlSize(.small)
                            .help("Opens Terminal to sign in")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor)))
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
        .accessibilityActions { if let signIn { Button("Sign In", action: signIn) } }
    }
}

// MARK: Storage

private struct StoragePane: View {
    @ObservedObject var model: SettingsModel

    private static let videoChoices = [(0, "Forever"), (30, "30 days"), (90, "90 days"), (180, "180 days"), (365, "1 year")]
    private static let audioChoices = [(0, "Forever"), (365, "1 year"), (90, "90 days")]

    var body: some View {
        SettingsGrid(spacing: 16) {
            SettingsRow(label: "Meetings folder") {
                HStack(spacing: 8) {
                    CodeText(text: (model.workspacePath as NSString).abbreviatingWithTildeInPath)
                    Button("Change…") { model.chooseWorkspace(for: NSApp.keyWindow) }
                }
            }
            SettingsRow(label: "In use") {
                HStack(spacing: 8) {
                    Text(model.usage.map(SettingsModel.usageText) ?? "Counting…")
                        .foregroundStyle(model.usage == nil ? .secondary : .primary)
                    Button("Clean Up Now", action: model.cleanUpNow).disabled(model.cleaning)
                    if let note = model.cleanUpNote { Hint(text: note).transition(.opacity) }
                }
                .animation(Motion.settle, value: model.cleanUpNote)
            }
        }

        Divider()

        SettingsGrid(spacing: 16) {
            SettingsRow(label: "Keep video") {
                VStack(alignment: .leading, spacing: 4) {
                    DaysPicker(label: "Keep video", days: $model.keepVideoDays, choices: Self.videoChoices)
                    Hint(text: "Then meeting.mp4 is deleted. Transcript, summary, notes and audio stay.")
                }
            }
            SettingsRow(label: "Keep audio tracks") {
                VStack(alignment: .leading, spacing: 4) {
                    DaysPicker(label: "Keep audio tracks", days: $model.keepAudioDays, choices: Self.audioChoices)
                    Hint(text: "The mic and Mac audio tracks, needed to redo a transcript.")
                }
            }
            SettingsRow(label: "Audio files") {
                Toggle("Compress after transcribing, without losing quality", isOn: $model.compressAudio)
            }
        }

        Divider()

        SettingsGrid(spacing: 16) {
            ForEach(model.models) { row in
                SettingsRow(label: row.label) {
                    HStack(spacing: 8) {
                        Text(row.name)
                        Group {
                            switch row.state {
                            case .installed: StatusBadge(text: "Installed", good: true)
                            case .notNeeded: StatusBadge(text: "Not needed")
                            case .downloading(let percent): StatusBadge(text: "Downloading · \(percent)%")
                            case .missing:
                                StatusBadge(text: "Missing")
                                Button("Download", action: model.downloadModels)
                                    .help(model.modelError ?? "")
                            }
                        }
                        .transition(.opacity)
                    }
                    .animation(Motion.settle, value: row.state.phase)
                }
            }
        }
    }
}

/// Day counts as a pop-up; a count set some other way is kept and shown as is.
private struct DaysPicker: View {
    let label: String
    @Binding var days: Int
    let choices: [(Int, String)]

    var body: some View {
        Picker(label, selection: $days) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var options: [(Int, String)] {
        choices.contains { $0.0 == days } ? choices : choices + [(days, "\(days) days")]
    }
}

private extension SettingsModel.ModelRow.State {
    /// The state without the percentage, so download progress itself does not animate.
    var phase: Int {
        switch self {
        case .installed: 0
        case .missing: 1
        case .notNeeded: 2
        case .downloading: 3
        }
    }
}

// MARK: Sync

private struct SyncPane: View {
    @ObservedObject var model: SyncModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Legend(text: "Sync meetings to")
            card(.off, "Off", "Meetings stay on this Mac.")
            card(.folder, "A folder synced by another app",
                 "Google Drive, iCloud Drive, OneDrive or Dropbox uploads it. Nothing to set up here.")
            card(.googleDrive, "Google Drive, signed in from Minutes",
                 "Uploads with your Google account. Needs a Google Cloud OAuth client.")
        }
        .sheet(item: $model.clientSheet) { sheet in
            GoogleClientSheet(sheet: sheet, save: model.saveClient, cancel: { model.clientSheet = nil })
        }

        switch model.mode {
        case .off:
            EmptyView()
        case .folder:
            Divider().transition(.opacity)
            FolderRows(model: model).transition(.opacity)
        case .googleDrive:
            Divider().transition(.opacity)
            DriveRows(model: model).transition(.opacity)
        }

        if model.mode != .off {
            Divider().transition(.opacity)
            SettingsGrid(spacing: 16) {
                SettingsRow(label: "What to sync") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Transcript, summary and notes", isOn: $model.uploadText)
                        Toggle("Video (or both audio tracks when there is none)", isOn: $model.uploadMedia)
                        Hint(text: "Meetings marked confidential are never synced.")
                    }
                }
                SettingsRow(label: "Groups") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("A folder for each group", isOn: $model.perGroup)
                        Hint(text: model.layout)
                    }
                }
                SettingsRow(label: "When deleted here") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Delete there too", isOn: $model.deleteThere)
                        Hint(text: "Also when clean-up deletes a video.")
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func card(_ mode: Settings.SyncMode, _ name: String, _ detail: String) -> some View {
        ProviderCard(name: name, detail: detail, status: nil, good: false, selected: model.mode == mode) {
            Motion.animate(Motion.reduced(reduceMotion) ? nil : Motion.appear) { model.mode = mode }
        }
    }
}

private struct FolderRows: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        SettingsGrid(spacing: 16) {
            SettingsRow(label: "Folder") {
                PlaceList(model: model)
            }
            if let place = model.place {
                SettingsRow(label: "Copies go to") {
                    HStack(spacing: 8) {
                        CodeText(text: place.shortDestination)
                            .help(FolderSync.destination(URL(fileURLWithPath: place.path)).path)
                        Button("Show in Finder", action: model.showInFinder).disabled(model.folderMissing)
                    }
                }
            }
            SettingsRow(label: "Status") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        status
                        if model.place != nil {
                            Button("Sync Now", action: model.syncNow)
                        }
                    }
                    if case .missing(let waiting) = model.status, waiting > 0 {
                        Hint(text: "\(SettingsModel.count(waiting, "meeting")) \(waiting == 1 ? "waits" : "wait") here and copy when it is back.")
                            .transition(.opacity)
                    }
                }
                .animation(Motion.settle, value: model.folderMissing)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.status {
        case .synced(let date, let meetings):
            StatusBadge(text: "Last synced \(Self.time(date)) · \(SettingsModel.count(meetings, "meeting"))", good: true)
        case .notSynced: StatusBadge(text: "Not synced yet")
        case .copying(let title): StatusBadge(text: "Copying \(title)…")
        case .noFolder: StatusBadge(text: "Choose a folder")
        case .missing:
            WarningBadge(text: model.place?.appName.map { "Folder not found — is \($0) running?" } ?? "Folder not found")
        case .failed(let text): WarningBadge(text: text)
        }
    }

    /// "09:12" today, "27 Oct 09:12" before.
    static func time(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_GB")
        format.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm"
        return format.string(from: date)
    }
}

/// The places a sync app uploads, found on this Mac, with Other Folder… under them.
private struct PlaceList: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        VStack(spacing: 0) {
            if model.listed.isEmpty {
                Text("No sync app found on this Mac")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
            }
            ForEach(model.listed) { place in
                row(place)
            }
            HStack {
                Button("Other Folder…") { model.chooseOther(for: NSApp.keyWindow) }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 440)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder")
    }

    private func row(_ place: SyncPlace) -> some View {
        let selected = model.folder == place.path
        return HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            PlaceIcon(place: place)
            VStack(alignment: .leading, spacing: 0) {
                Text(place.name)
                Text(place.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .contentShape(Rectangle())
        .onTapGesture { model.choose(place) }
        .help(place.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.choose(place) }
    }
}

/// Every place as the same quiet glyph on a soft tile.
private struct PlaceIcon: View {
    let place: SyncPlace

    var body: some View {
        Group {
            if place.kind == .googleDrive {
                DriveGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
                    .frame(width: 15, height: 15)
            } else {
                Image(systemName: place.symbol).font(.system(size: 12))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

/// Google Drive's triangle, drawn on a 24-point grid.
private struct DriveGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.addLines([p(8.5, 4), p(15.5, 4), p(21.5, 14.5), p(18, 20.5), p(6, 20.5), p(2.5, 14.5)])
        path.closeSubpath()
        path.addLines([p(8.5, 4), p(14.5, 14.5), p(21.5, 14.5)])
        path.addLines([p(2.5, 14.5), p(14.5, 14.5), p(18, 20.5)])
        return path
    }
}

/// Orange dot and words for something that needs the user: the folder is away or a copy failed.
private struct WarningBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.statusWarning).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.statusWarning)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension Color {
    /// #a34a00 on light, the system orange on dark.
    static let statusWarning = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange : NSColor(srgbRed: 0.639, green: 0.290, blue: 0, alpha: 1)
    })
}

private struct DriveRows: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        SettingsGrid(spacing: 16) {
            SettingsRow(label: "Account") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Group {
                            if model.connectingDrive {
                                StatusBadge(text: "Waiting for Google sign-in…")
                            } else if model.driveConnected {
                                StatusBadge(text: "Connected", good: true)
                                Button("Upload Now", action: model.uploadNow)
                                Button("Disconnect", action: model.disconnectDrive)
                            } else {
                                StatusBadge(text: "Not connected")
                                Button("Connect…", action: model.connectDrive)
                            }
                        }
                        .transition(.opacity)
                    }
                    if let status = model.driveStatus { Hint(text: status).transition(.opacity) }
                }
                .animation(Motion.settle, value: model.driveConnected)
                .animation(Motion.settle, value: model.connectingDrive)
                .animation(Motion.settle, value: model.driveStatus == nil)
            }
            SettingsRow(label: "OAuth client") {
                HStack(spacing: 8) {
                    if let clientID = model.clientID {
                        CodeText(text: clientID)
                    } else {
                        Text("Not set").foregroundStyle(.secondary)
                    }
                    Button("Edit…", action: model.editGoogleClient)
                }
            }
        }
    }
}
