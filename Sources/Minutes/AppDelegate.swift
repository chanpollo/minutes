import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = MicMonitor()

    private var recording: Recording?
    private var transcribing = 0
    private var prompt: PromptPanel?
    private var promptedApp: String?
    private var declined = Set<String>()
    private var micPolls: [String: Int] = [:]
    private var micFreeSince: Date?

    // The mic must stay open this many 2-second polls before asking, so a quick voice memo does not trigger it.
    private let pollsBeforePrompt = 2
    // Some apps release the mic while muted; wait this long before treating the call as over.
    private let autoStopAfter: TimeInterval = 30

    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        monitor.onChange = { [weak self] users in self?.micUsersChanged(users) }
        monitor.start()
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        recording?.stop()
    }

    // MARK: Meeting detection

    private func micUsersChanged(_ users: [MicUser]) {
        let apps = Set(users.filter(\.isMeetingCandidate).map(\.appName))
        declined.formIntersection(apps)
        micPolls = Dictionary(uniqueKeysWithValues: apps.map { ($0, (micPolls[$0] ?? 0) + 1) })

        if let recording {
            guard recording.autoStop else { return }
            if !apps.isEmpty {
                micFreeSince = nil
            } else if let since = micFreeSince {
                if Date().timeIntervalSince(since) >= autoStopAfter { stopRecording() }
            } else {
                micFreeSince = Date()
            }
            return
        }

        if let promptedApp, !apps.contains(promptedApp) { closePrompt() }
        guard prompt == nil,
              let app = apps.sorted().first(where: { micPolls[$0, default: 0] >= pollsBeforePrompt && !declined.contains($0) })
        else { return }
        askToRecord(app)
    }

    private func askToRecord(_ app: String) {
        promptedApp = app
        prompt = PromptPanel(
            title: "Record this meeting?",
            message: "\(app) is using the microphone.",
            buttons: [
                ("Record", { [weak self] in self?.startRecording(app: app, autoStop: true) }),
                ("Not now", { [weak self] in self?.declined.insert(app); self?.prompt = nil }),
            ])
        prompt?.show()
    }

    private func closePrompt() {
        prompt?.close()
        prompt = nil
        promptedApp = nil
    }

    // MARK: Recording

    private func startRecording(app: String?, autoStop: Bool) {
        closePrompt()
        do {
            let recording = try Recording(appName: app, autoStop: autoStop)
            try recording.start()
            self.recording = recording
            micFreeSince = nil
        } catch {
            show(error)
        }
        refreshMenu()
    }

    @objc private func recordNow() {
        startRecording(app: nil, autoStop: false)
    }

    @objc private func stopRecording() {
        guard let finished = recording else { return }
        finished.stop()
        recording = nil
        // The call app may still hold the mic after a manual stop; do not ask again for the same call.
        if let app = finished.appName { declined.insert(app) }
        transcribing += 1
        refreshMenu()

        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Transcriber.transcribe(finished) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.transcribing -= 1
                self.refreshMenu()
                self.announce(result, for: finished)
            }
        }
    }

    private func announce(_ result: Result<URL, Error>, for recording: Recording) {
        let panel: PromptPanel
        switch result {
        case .success(let transcript):
            panel = PromptPanel(
                title: "Transcript ready",
                message: recording.title,
                buttons: [
                    ("Open", { NSWorkspace.shared.open(transcript) }),
                    ("Close", {}),
                ], timeout: 60)
        case .failure(let error):
            panel = PromptPanel(
                title: "Transcription failed",
                message: error.localizedDescription,
                buttons: [
                    ("Show Recording", { NSWorkspace.shared.open(recording.folder) }),
                    ("Close", {}),
                ], timeout: 0)
        }
        panel.show()
    }

    private func show(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not start recording"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Menu

    private func refreshMenu() {
        let symbol: String
        if recording != nil {
            symbol = "record.circle.fill"
        } else if transcribing > 0 {
            symbol = "text.bubble"
        } else {
            symbol = "mic"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Minutes")
        statusItem.button?.contentTintColor = recording != nil ? .systemRed : nil

        let menu = NSMenu()
        menu.addItem(withTitle: statusText, action: nil, keyEquivalent: "").isEnabled = false
        if recording != nil {
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "s").target = self
        } else {
            menu.addItem(withTitle: "Record Now", action: #selector(recordNow), keyEquivalent: "r").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Meetings Folder", action: #selector(openFolder), keyEquivalent: "o").target = self
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Minutes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private var statusText: String {
        if let recording {
            let time = DateFormatter.localizedString(from: recording.startedAt, dateStyle: .none, timeStyle: .short)
            return "Recording \(recording.appName ?? "") since \(time)".replacingOccurrences(of: "  ", with: " ")
        }
        if transcribing > 0 { return "Transcribing…" }
        return "Waiting for a meeting"
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Recording.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Recording.root)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        refreshMenu()
    }
}
