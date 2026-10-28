import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = MicMonitor()

    private var recording: Recording?
    private var transcribing = 0
    private var summarising = 0
    private var prompt: PromptPanel?
    private var promptedApp: String?
    private var declined = Set<String>()
    private var micPolls: [String: Int] = [:]
    private var micBundles: [String: String] = [:]
    private var micFreeSince: Date?
    private var summarisingIDs = Set<String>()
    private var connectingDrive = false

    // Transcription is CPU-heavy and summaries wait on the network: one job at a time on each.
    private let transcribeQueue = DispatchQueue(label: "minutes.transcribe", qos: .utility)
    private let summaryQueue = DispatchQueue(label: "minutes.summary", qos: .utility)

    // The mic must stay open this many 2-second polls before asking, so a quick voice memo does not trigger it.
    private let pollsBeforePrompt = 2
    // Some apps release the mic while muted; wait this long before treating the call as over.
    private let autoStopAfter: TimeInterval = 30

    private var recordScreen: Bool {
        get { UserDefaults.standard.object(forKey: "recordScreen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "recordScreen") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if recordScreen && !ScreenRecorder.hasPermission() { ScreenRecorder.requestPermission() }
        monitor.onChange = { [weak self] users in self?.micUsersChanged(users) }
        monitor.start()

        NotesWindowController.shared.onSummarise = { [weak self] id, model in self?.summarise(id, model: model) }
        NotesWindowController.shared.onChanged = { id in DriveSync.shared.enqueue(meetingID: id) }
        NotificationCenter.default.addObserver(forName: .driveStatusChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMenu()
        }
        recoverStaged()
        resumeTranscripts()
        DriveSync.shared.enqueuePending()
        refreshMenu()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let work: String
        if recording != nil {
            work = "A meeting is being recorded. It is kept and transcribed on the next launch."
        } else if transcribing > 0 {
            work = "A transcript is being made. It starts again on the next launch."
        } else if summarising > 0 {
            work = "A summary is being written. It is lost if you quit now."
        } else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit Minutes?"
        alert.informativeText = work
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let recording else { return }
        // The audio is safe once stopped; give the screen file a moment to finish. The next launch picks the folder up.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await recording.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    // MARK: Meeting detection

    private func micUsersChanged(_ users: [MicUser]) {
        let candidates = users.filter(\.isMeetingCandidate)
        let apps = Set(candidates.map(\.appName))
        micBundles = Dictionary(candidates.map { ($0.appName, $0.bundleID) }, uniquingKeysWith: { first, _ in first })
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
        askToRecord(app, bundleID: micBundles[app])
    }

    private func askToRecord(_ app: String, bundleID: String?) {
        promptedApp = app
        prompt = PromptPanel(
            title: "Record this meeting?",
            message: "\(app) is using the microphone.",
            fieldValue: "\(app) meeting",
            buttons: [
                ("Record", { [weak self] in
                    guard let self else { return }
                    self.startRecording(app: app, bundleID: bundleID, title: self.prompt?.fieldText ?? "", autoStop: true)
                }),
                ("Not now", { [weak self] in self?.declined.insert(app); self?.prompt = nil }),
            ])
        // Unanswered counts as "Not now" so another app can still be offered.
        prompt?.onTimeout = { [weak self] in
            self?.declined.insert(app)
            self?.prompt = nil
            self?.promptedApp = nil
        }
        prompt?.show()
    }

    private func closePrompt() {
        prompt?.close()
        prompt = nil
        promptedApp = nil
    }

    // MARK: Recording

    private func startRecording(app: String?, bundleID: String?, title: String, autoStop: Bool) {
        closePrompt()
        var started: Recording?
        do {
            let recording = try Recording(
                appName: app, bundleID: bundleID, title: title, autoStop: autoStop, recordScreen: recordScreen)
            started = recording
            try recording.start()
            self.recording = recording
            micFreeSince = nil
        } catch {
            if let started { try? FileManager.default.removeItem(at: started.folder) }
            showAlert("Could not start recording", error)
        }
        refreshMenu()
    }

    @objc private func recordNow() {
        startRecording(app: nil, bundleID: nil, title: "Meeting", autoStop: false)
    }

    @objc private func stopRecording() {
        guard let finished = recording else { return }
        recording = nil
        // The call app may still hold the mic after a manual stop; do not ask again for the same call.
        if let app = finished.appName { declined.insert(app) }
        transcribing += 1
        refreshMenu()

        Task { @MainActor [weak self] in
            await finished.stop()
            self?.process(finished.folder, staged: true, screenError: finished.screenError)
        }
    }

    /// Recordings left in staging by a quit or crash: repair, move in and transcribe them.
    private func recoverStaged() {
        let staged = (try? FileManager.default.contentsOfDirectory(
            at: Workspace.staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in staged where Workspace.readMeta(folder) != nil {
            transcribing += 1
            process(folder, staged: true, recovered: true)
        }
    }

    /// Meetings whose transcription was cut off by a quit: transcribe them again.
    private func resumeTranscripts() {
        let files = FileManager.default
        for (folder, meta) in Workspace.meetings() where meta.transcriptError == nil {
            guard !files.fileExists(atPath: folder.appendingPathComponent("transcript.md").path),
                  ["me.wav", "others.wav"].contains(where: { files.fileExists(atPath: folder.appendingPathComponent($0).path) })
            else { continue }
            transcribing += 1
            process(folder, staged: false)
        }
    }

    /// Video, then the move into the workspace, then the transcript. The caller has counted it in `transcribing`.
    private func process(_ start: URL, staged: Bool, recovered: Bool = false, screenError: Error? = nil) {
        transcribeQueue.async { [weak self] in
            var problems = screenError.map { ["Video not recorded: \($0.localizedDescription)"] } ?? []
            var folder = start
            if staged {
                let tracks = [folder.appendingPathComponent("me.wav"), folder.appendingPathComponent("others.wav")]
                if recovered {
                    tracks.forEach(TrackWriter.repairHeader)
                    let lastWrite = tracks.compactMap {
                        try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    }.max()
                    _ = try? Workspace.updateMeta(folder) { if $0.endedAt == nil { $0.endedAt = lastWrite } }
                }
                let screen = folder.appendingPathComponent("screen.mov")
                if FileManager.default.fileExists(atPath: screen.path) {
                    let offset = Workspace.readMeta(folder)?.videoOffset
                    if offset == nil { problems.append("Video timing unknown; picture and sound may be out of step.") }
                    do {
                        try Muxer.mux(
                            video: screen, audio: tracks, videoOffset: offset ?? 0,
                            to: folder.appendingPathComponent("meeting.mp4"))
                        try? FileManager.default.removeItem(at: screen)
                    } catch {
                        problems.append("Video not combined: \(error.localizedDescription)")
                    }
                }
                do {
                    folder = try Workspace.moveIn(folder)
                } catch {
                    DispatchQueue.main.async { self?.transcribed(.failure(error), folder: start, meta: nil, problems: problems) }
                    return
                }
            }

            let meta = Workspace.readMeta(folder)
            let result = Result {
                try Transcriber.transcribe(
                    folder: folder, title: meta?.title ?? folder.lastPathComponent, startedAt: meta?.startedAt ?? Date(),
                    id: meta?.id)
            }
            if let id = meta?.id {
                let current = Workspace.folder(id: id) ?? folder
                _ = try? Workspace.updateMeta(current) {
                    if case .failure(let error) = result { $0.transcriptError = error.localizedDescription } else { $0.transcriptError = nil }
                }
                DriveSync.shared.enqueue(meetingID: id)
            }
            Workspace.notifyChanged()
            DispatchQueue.main.async { self?.transcribed(result, folder: folder, meta: meta, problems: problems) }
        }
    }

    private func transcribed(_ result: Result<URL, Error>, folder: URL, meta: MeetingMeta?, problems: [String]) {
        transcribing -= 1
        refreshMenu()
        let title = meta?.title ?? folder.lastPathComponent
        let notes = problems.map { "\n\($0)" }.joined()
        let panel: PromptPanel
        switch result {
        case .success:
            var buttons: [(String, () -> Void)] = []
            if let id = meta?.id {
                buttons.append(("Summarise", { [weak self] in self?.summarise(id, model: SummaryModel.current) }))
                buttons.append(("Open", { NotesWindowController.shared.show(meetingID: id) }))
            } else {
                buttons.append(("Show in Finder", { NSWorkspace.shared.open(folder) }))
            }
            buttons.append(("Close", {}))
            panel = PromptPanel(title: "Transcript ready", message: title + notes, buttons: buttons, timeout: 60)
        case .failure(let error):
            panel = PromptPanel(
                title: "Transcription failed",
                message: "\(title)\n\(error.localizedDescription)\(notes)",
                buttons: [
                    ("Show Recording", { NSWorkspace.shared.open(folder) }),
                    ("Close", {}),
                ], timeout: 0)
        }
        panel.show()
    }

    // MARK: Summary

    private func summarise(_ id: String, model: SummaryModel) {
        guard !summarisingIDs.contains(id), Workspace.folder(id: id) != nil else { return }
        summarisingIDs.insert(id)
        summarising += 1
        NotesWindowController.shared.setBusy(id, true)
        refreshMenu()

        summaryQueue.async { [weak self] in
            // Looked up again here: the meeting may have been renamed while waiting.
            let result = Result { () throws -> URL in
                guard let folder = Workspace.folder(id: id) else { throw CocoaError(.fileNoSuchFile) }
                return try Summarizer.summarize(folder: folder, model: model)
            }
            if case .success = result { DriveSync.shared.enqueue(meetingID: id) }
            let title = Workspace.folder(id: id).flatMap(Workspace.readMeta)?.title ?? "Meeting"
            DispatchQueue.main.async {
                guard let self else { return }
                self.summarising -= 1
                self.summarisingIDs.remove(id)
                NotesWindowController.shared.setBusy(id, false)
                self.refreshMenu()
                self.summarised(result, id: id, title: title)
            }
        }
    }

    private func summarised(_ result: Result<URL, Error>, id: String, title: String) {
        let panel: PromptPanel
        switch result {
        case .success:
            panel = PromptPanel(
                title: "Summary ready",
                message: title,
                buttons: [
                    ("Open", { NotesWindowController.shared.show(meetingID: id) }),
                    ("Close", {}),
                ], timeout: 60)
        case .failure(let error):
            panel = PromptPanel(
                title: "Summary failed",
                message: "\(title)\n\(error.localizedDescription)",
                buttons: [("Close", {})], timeout: 0)
        }
        panel.show()
    }

    @objc private func summariseLast() {
        let last = Workspace.meetings().first {
            FileManager.default.fileExists(atPath: $0.folder.appendingPathComponent("transcript.md").path)
        }
        guard let last else { return }
        summarise(last.meta.id, model: SummaryModel.current)
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let model = SummaryModel(rawValue: raw) else { return }
        SummaryModel.current = model
        refreshMenu()
    }

    // MARK: Menu

    private func refreshMenu() {
        let symbol: String
        if recording != nil {
            symbol = "record.circle.fill"
        } else if transcribing + summarising > 0 {
            symbol = "text.bubble"
        } else {
            symbol = "mic"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Minutes")
        statusItem.button?.contentTintColor = recording != nil ? .systemRed : nil

        let menu = NSMenu()
        menu.addItem(withTitle: statusText, action: nil, keyEquivalent: "").isEnabled = false
        if let drive = DriveSync.shared.status {
            menu.addItem(withTitle: drive, action: nil, keyEquivalent: "").isEnabled = false
        }
        if recording != nil {
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "s").target = self
        } else {
            menu.addItem(withTitle: "Record Now", action: #selector(recordNow), keyEquivalent: "r").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Minutes", action: #selector(openNotes), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Summarise Last Meeting", action: #selector(summariseLast), keyEquivalent: "").target = self
        let models = NSMenu()
        for model in SummaryModel.allCases {
            let item = models.addItem(withTitle: model.label, action: #selector(pickModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.rawValue
            item.state = model == SummaryModel.current ? .on : .off
        }
        menu.addItem(withTitle: "Summary Model", action: nil, keyEquivalent: "").submenu = models

        menu.addItem(.separator())
        let screen = menu.addItem(withTitle: "Record Screen", action: #selector(toggleScreen), keyEquivalent: "")
        screen.target = self
        screen.state = recordScreen ? .on : .off

        let workspace = NSMenu()
        workspace.addItem(withTitle: Workspace.root.path, action: nil, keyEquivalent: "").isEnabled = false
        workspace.addItem(withTitle: "Choose Folder…", action: #selector(chooseWorkspace), keyEquivalent: "").target = self
        workspace.addItem(withTitle: "Show in Finder", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Workspace", action: nil, keyEquivalent: "").submenu = workspace

        let drive = NSMenu()
        if connectingDrive {
            drive.addItem(withTitle: "Waiting for Google sign-in…", action: nil, keyEquivalent: "").isEnabled = false
        } else if DriveSync.shared.isConnected {
            drive.addItem(withTitle: "Upload Now", action: #selector(uploadNow), keyEquivalent: "").target = self
            drive.addItem(withTitle: "Disconnect", action: #selector(disconnectDrive), keyEquivalent: "").target = self
        } else {
            drive.addItem(withTitle: "Connect…", action: #selector(connectDrive), keyEquivalent: "").target = self
        }
        drive.addItem(withTitle: "OAuth Client…", action: #selector(editGoogleClient), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Google Drive", action: nil, keyEquivalent: "").submenu = drive

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
            return "Recording \(recording.title) since \(time)"
        }
        if transcribing > 0 { return "Transcribing…" }
        if summarising > 0 { return "Summarising…" }
        return "Waiting for a meeting"
    }

    @objc private func openNotes() {
        NotesWindowController.shared.show()
    }

    @objc private func toggleScreen() {
        recordScreen.toggle()
        if recordScreen && !ScreenRecorder.hasPermission() { ScreenRecorder.requestPermission() }
        refreshMenu()
    }

    @objc private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = Workspace.root
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Workspace.root = url
        Workspace.notifyChanged()
        refreshMenu()
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Workspace.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Workspace.root)
    }

    // MARK: Google Drive

    @objc private func connectDrive() {
        guard !connectingDrive else { return }
        if DriveSync.clientID == nil || DriveSync.clientSecret == nil {
            guard askForGoogleClient() else { return }
        }
        connectingDrive = true
        refreshMenu()
        DriveSync.shared.connect { [weak self] error in
            self?.connectingDrive = false
            if let error {
                self?.showAlert("Could not connect Google Drive", error)
            } else {
                DriveSync.shared.enqueuePending()
            }
            self?.refreshMenu()
        }
    }

    @objc private func editGoogleClient() {
        _ = askForGoogleClient()
    }

    private func askForGoogleClient() -> Bool {
        let id = NSTextField(string: DriveSync.clientID ?? "")
        id.placeholderString = "Client ID"
        let secret = NSSecureTextField(string: DriveSync.clientSecret ?? "")
        secret.placeholderString = "Client secret"
        let fields = NSStackView(views: [id, secret])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 340, height: 52)
        id.frame.size.width = 340
        secret.frame.size.width = 340

        let alert = NSAlert()
        alert.messageText = "Google OAuth client"
        alert.informativeText = "Client ID and secret of a Desktop app OAuth client from Google Cloud Console."
        alert.accessoryView = fields
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let clientID = id.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else { return false }
        DriveSync.clientID = clientID
        DriveSync.clientSecret = clientSecret
        return true
    }

    @objc private func disconnectDrive() {
        DriveSync.shared.disconnect()
        refreshMenu()
    }

    @objc private func uploadNow() {
        DriveSync.shared.enqueuePending()
    }

    // MARK: Misc

    private func showAlert(_ title: String, _ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
