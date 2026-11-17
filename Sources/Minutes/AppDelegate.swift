import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = MicMonitor()

    private var recording: Recording?
    private var transcribing = 0
    private var summarising = 0
    private var prompt: PromptPanel?
    private var promptedApp: String?
    private var detector = MeetingDetector()
    private var micOwners = Set<String>()
    private var stopPrompt: PromptPanel?
    private var sameCallPrompt: PromptPanel?
    private var recordingCard: PromptPanel?
    private var pendingTitle: (() -> Void)?
    private var summarisingIDs = Set<String>()
    private var summarisingTitles: [String: String] = [:]
    private var waitingForModels = Set<String>()
    private var queue = TranscriptionQueue()
    private let menuBar = MenuBarMenu()
    private lazy var glyph = RecordingGlyph(button: statusItem.button)

    // Transcription is CPU-heavy and summaries wait on the network: one job at a time on each.
    private let transcribeQueue = DispatchQueue(label: "minutes.transcribe", qos: .utility)
    private let summaryQueue = DispatchQueue(label: "minutes.summary", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdater.shared.isBusy = { [weak self] in
            guard let self else { return true }
            return self.recording != nil || self.transcribing > 0 || self.summarising > 0
                || !BriefingCenter.shared.jobs.isEmpty || !BriefingCenter.shared.saving.isEmpty
        }
        AppUpdater.shared.start()
        Settings.migrateRecordScreen()
        // Re-run with… lists Gemini models from this cache.
        AgyEngine.refreshModels {}
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Voice never records the screen, so it does not ask for it.
        if Settings.recordMode == .screen && !ScreenRecorder.hasPermission() { ScreenRecorder.requestPermission() }
        if (Settings.titleFromCalendar || Settings.confidentialExternal) && CalendarTitle.status == .notDetermined {
            CalendarTitle.requestAccess()
        }
        monitor.onChange = { [weak self] users in self?.micUsersChanged(users) }
        monitor.start()

        // Asked for from the notes window on one meeting, so a confidential mark does not stop it.
        NotesWindowController.shared.onSummarise = { [weak self] id, model in self?.summarise(id, model: model, force: true) }
        NotesWindowController.shared.onChanged = { id in Sync.shared.enqueue(meetingID: id) }
        NotesWindowController.shared.onRecord = { [weak self] entry in self?.toggleRecording(entry) }
        NotesWindowController.shared.onStop = { [weak self] in self?.stopRecording() }
        Hotkey.shared.onPress = { [weak self] in self?.toggleRecording(.shortcut) }
        Hotkey.shared.register(Settings.recordShortcut)

        menuBar.actions = MenuBarMenu.Actions(
            record: { [weak self] mode in self?.recordNow(.menu(mode)) },
            stop: { [weak self] in self?.stopRecording() },
            discard: { [weak self] in self?.discardRecording() },
            openNotes: { [weak self] in self?.openNotes() },
            newNote: { [weak self] in self?.newNote() },
            openFolder: { [weak self] in self?.openFolder() },
            settings: { SettingsWindowController.shared.show() },
            about: { VersionsWindowController.shared.show() },
            downloadModels: { ModelStore.shared.start() },
            playBriefing: { BriefingCenter.shared.playLatest() },
            mute: { [weak self] in self?.toggleMute() })
        MicMute.shared.onToggle = { [weak self] in self?.toggleMute() }
        BriefingCenter.shared.onChange = { [weak self] in self?.refreshMenu() }
        BriefingCenter.shared.onMade = { id in Sync.shared.enqueue(meetingID: id) }
        BriefingCenter.shared.onError = { [weak self] error in self?.briefingFailed(error) }
        menuBar.status = { [weak self] in self?.menuStatus ?? .waiting(label: "Waiting for a meeting") }
        statusItem.menu = menuBar.menu

        for name in [Notification.Name.driveStatusChanged, .syncStatusChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.menuBar.update()
            }
        }
        ModelStore.shared.onChange = { [weak self] in
            self?.refreshMenu()
            self?.retryWaitingForModels()
            SettingsWindowController.shared.refresh()
        }
        ModelStore.shared.onProgress = { [weak self] in
            self?.menuBar.update()
            SettingsWindowController.shared.refresh()
        }
        ModelStore.shared.start()
        recoverStaged()
        resumeTranscripts()
        Sync.shared.start()
        Housekeeping.start()
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
        glyph.stop()
        OllamaEngine.stop()
        FrameExtractor.shared.cancelAll()
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
        rememberMicApps(candidates)
        detector.autoStopAfter = TimeInterval(Settings.autoStopSeconds)
        let calendar = Settings.titleFromCalendar || Settings.confidentialExternal
        let actions = detector.poll(
            candidates, now: Date(), recording: recording.map { .init(app: $0.appName, autoStop: $0.autoStop) },
            prompted: prompt == nil ? nil : promptedApp, stopPromptShown: stopPrompt != nil,
            isAllowed: MeetingApps.isAllowed, alwaysRecord: { Settings.alwaysRecord.contains($0) },
            meetingStarted: { calendar && CalendarTitle.meetingStarted(appBundleID: $0, since: $1) },
            outputApps: monitor.outputApps)
        for action in actions {
            switch action {
            case .closePrompt: closePrompt()
            case .ask(let app, let bundleID): askToRecord(app, bundleID: bundleID)
            case .recordWithoutAsking(let app, let bundleID): recordWithoutAsking(app, bundleID: bundleID)
            case .closeStopPrompt: closeStopPrompt()
            case .askToStop(let remaining): if let recording { askToStop(recording, remaining: remaining) }
            case .askSameCall(let app): if let recording { askSameCall(recording, app: app) }
            case .stop: stop(byHand: false)
            }
        }
    }

    /// Remembers apps when they take the mic, for the Settings list.
    private func rememberMicApps(_ candidates: [MicUser]) {
        let owners = Dictionary(candidates.map { ($0.ownerBundleID, $0.appName) }, uniquingKeysWith: { first, _ in first })
        let fresh = owners.filter { !micOwners.contains($0.key) }.map { MeetingApps.App(bundleID: $0.key, name: $0.value) }
        micOwners = Set(owners.keys)
        if !fresh.isEmpty, MeetingApps.remember(fresh) { SettingsWindowController.shared.refresh() }
    }

    private func askToRecord(_ app: String, bundleID: String?) {
        promptedApp = app
        let (event, external) = calendarEvent(bundleID: bundleID)
        let mode = Settings.mode(forApp: bundleID)
        prompt = PromptPanel(
            icon: .microphone,
            title: "Record this meeting?",
            message: "\(app) is using the microphone.",
            detail: mode.cardDetail,
            fieldValue: event?.title ?? "\(app) meeting",
            mode: mode,
            checkbox: bundleID.map { _ in "Always record \(app)" },
            buttons: [
                (mode.item, { [weak self] in
                    guard let self else { return }
                    // Kept only when the user goes on to record, so ticking it and then choosing Not now changes nothing.
                    if let bundleID, self.prompt?.isChecked == true, !Settings.alwaysRecord.contains(bundleID) {
                        Settings.alwaysRecord.append(bundleID)
                    }
                    let mode = RecordEntry.card(self.prompt?.mode ?? mode, bundleID: bundleID).apply()
                    let title = self.prompt?.fieldText ?? ""
                    let typed = Self.typedOver(event, title: title)
                    self.startRecording(
                        app: app, bundleID: bundleID, title: title, event: typed ? nil : event, external: !typed && external,
                        autoStop: true, mode: mode)
                }),
                ("Not now", { [weak self] in self?.detector.decline(app, at: Date()); self?.prompt = nil }),
            ],
            primary: .record)
        // Unanswered counts as "Not now" so another app can still be offered.
        prompt?.onTimeout = { [weak self] in
            self?.detector.decline(app, at: Date())
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

    /// "Always record <App>": starts at once and says so on a card that goes away by itself.
    private func recordWithoutAsking(_ app: String, bundleID: String) {
        let (event, external) = calendarEvent(bundleID: bundleID)
        startRecording(
            app: app, bundleID: bundleID, title: event?.title ?? "\(app) meeting", event: event, external: external,
            autoStop: true, mode: RecordEntry.always(bundleID: bundleID).apply())
        guard let recording else { return }
        recordingCard = PromptPanel(
            icon: .microphone,
            title: "Recording \(app)",
            message: recording.title,
            detail: recording.mode.cardDetail,
            buttons: [
                ("OK", { [weak self] in self?.recordingCard = nil }),
                ("Stop", { [weak self] in self?.recordingCard = nil; self?.stopRecording() }),
            ],
            timeout: 12)
        recordingCard?.onTimeout = { [weak self] in self?.recordingCard = nil }
        recordingCard?.show()
    }

    // Hanging up releases the mic, but so do some apps on mute: offer an immediate stop and stop anyway after autoStopAfter.
    private func askToStop(_ recording: Recording, remaining: TimeInterval) {
        closeSameCallPrompt()
        stopPrompt = PromptPanel(
            icon: .microphone,
            title: "Stop recording?",
            message: "\(recording.appName ?? "The call") released the microphone.",
            detail: "Recording stops by itself in \(Int(remaining.rounded())) seconds.",
            buttons: [
                ("Stop", { [weak self] in self?.stopPrompt = nil; self?.stopRecording() }),
                ("Keep Recording", { [weak self] in self?.stopPrompt = nil; self?.detector.keepRecording = true }),
            ],
            timeout: remaining)
        stopPrompt?.onTimeout = { [weak self] in self?.stopPrompt = nil; self?.stop(byHand: false) }
        stopPrompt?.show()
    }

    private func closeStopPrompt() {
        stopPrompt?.close()
        stopPrompt = nil
    }

    /// The call app took the mic back after the stop card: the next call joined straight after, or a mute ended.
    /// Unanswered, a calendar meeting for the app that began during the recording means the next call.
    private func askSameCall(_ recording: Recording, app: String) {
        closeSameCallPrompt()
        let newMeeting = { [weak self, weak recording] in
            guard let self, let recording, self.recording === recording else { return }
            self.stop(byHand: false)
        }
        sameCallPrompt = PromptPanel(
            icon: .microphone,
            title: "Is this a new meeting?",
            message: "\(app) is using the microphone again.",
            detail: "New Meeting stops \(recording.title) and records the call as a meeting of its own.",
            buttons: [
                ("New Meeting", { [weak self] in self?.sameCallPrompt = nil; newMeeting() }),
                ("Same Meeting", { [weak self] in self?.sameCallPrompt = nil }),
            ],
            timeout: 30)
        sameCallPrompt?.onTimeout = { [weak self, weak recording] in
            self?.sameCallPrompt = nil
            guard let recording else { return }
            let calendar = Settings.titleFromCalendar || Settings.confidentialExternal
            if calendar, CalendarTitle.meetingStarted(appBundleID: recording.bundleID, since: recording.startedAt) {
                newMeeting()
            }
        }
        sameCallPrompt?.show()
    }

    private func closeSameCallPrompt() {
        sameCallPrompt?.close()
        sameCallPrompt = nil
    }

    // MARK: Recording

    /// The event on now, for its title and invitees when Settings say so, and whether anyone invited is external.
    /// `voice` is a Voice recording of no app: an event with a call link is likely another meeting and does not mark it.
    private func calendarEvent(bundleID: String?, voice: Bool = false) -> (event: CalendarEvent?, external: Bool) {
        guard Settings.titleFromCalendar || Settings.confidentialExternal else { return (nil, false) }
        let event = CalendarTitle.current(appBundleID: bundleID, voice: voice)
        let external = event.map { $0.hasExternal && !(voice && CalendarTitle.hasCallLink($0)) } ?? false
        return (Settings.titleFromCalendar ? event : nil, external)
    }

    private func startRecording(
        app: String?, bundleID: String?, title: String, event: CalendarEvent?, external: Bool, autoStop: Bool,
        mode: RecordMode, note: MeetingMeta? = nil
    ) {
        closePrompt()
        var started: Recording?
        do {
            let recording = try Recording(
                appName: app, bundleID: bundleID, title: title, attendees: event?.attendees, autoStop: autoStop,
                mode: mode, note: note)
            started = recording
            if Settings.confidentialExternal, external {
                try Workspace.updateMeta(recording.folder) { $0.confidential = true }
            }
            try recording.start()
            self.recording = recording
            pushLive()
            detector.recordingStarted()
        } catch {
            if let started { try? FileManager.default.removeItem(at: started.folder) }
            showAlert("Could not start recording", error)
        }
        refreshMenu()
    }

    /// "Record Now": a recording of no app, from the shortcut, a menu or the window's Record button.
    private func recordNow(_ entry: RecordEntry) {
        guard recording == nil else { return }
        // With a Record card up, the start is taken as that card's call: its window, its title and its auto-stop.
        if let prompt, let app = promptedApp {
            let bundleID = detector.bundles[app]
            let (event, external) = calendarEvent(bundleID: bundleID)
            let mode: RecordMode
            if case .menu = entry {
                mode = entry.apply()
            } else {
                mode = RecordEntry.card(prompt.mode ?? Settings.mode(forApp: bundleID), bundleID: bundleID).apply()
            }
            let typed = Self.typedOver(event, title: prompt.fieldText)
            startRecording(
                app: app, bundleID: bundleID, title: prompt.fieldText, event: typed ? nil : event,
                external: !typed && external, autoStop: true, mode: mode)
            return
        }
        let mode = entry.apply()
        // With a note open in the window, the recording goes into it and keeps the note's title; the calendar event is
        // left out altogether, its external guests included.
        if let note = NotesWindowController.shared.openNote {
            startRecording(
                app: nil, bundleID: nil, title: note.title, event: nil, external: false, autoStop: false, mode: mode,
                note: note)
            return
        }
        // Pressed by hand, the talk is often not the event booked at this time: it starts unnamed and the card offers
        // the events that are on.
        startRecording(app: nil, bundleID: nil, title: "Meeting", event: nil, external: false, autoStop: false, mode: mode)
        if let recording { askTitle(recording, voice: mode == .voice) }
    }

    /// The title on the Record? card no longer the event's: the user named another meeting, so its invitees go too.
    private static func typedOver(_ event: CalendarEvent?, title: String) -> Bool {
        guard let event else { return false }
        return Workspace.cleanTitle(title) != Workspace.cleanTitle(event.title)
    }

    /// The card after Record Now: a title field and the calendar events on now; Done or the timeout keeps the choice.
    private func askTitle(_ recording: Recording, voice: Bool) {
        let events = Settings.titleFromCalendar || Settings.confidentialExternal
            ? CalendarTitle.on(appBundleID: nil, voice: voice, at: recording.startedAt) : []
        var picked: CalendarEvent?
        var markedConfidential = false
        let apply = { [weak self, weak recording] in
            guard let self, let recording, let card = self.recordingCard else { return }
            let title = card.fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
            let event = picked.flatMap { Self.typedOver($0, title: title) ? nil : $0 }
            let confidential = Settings.confidentialExternal && event?.hasExternal == true
            do {
                try recording.retitle(
                    title.isEmpty ? "Meeting" : title, attendees: event?.attendees,
                    confidential: confidential ? true : (markedConfidential ? false : nil))
                markedConfidential = confidential
            } catch {
                NSLog("Minutes: retitle failed: %@", error.localizedDescription)
            }
            self.pushLive()
            self.refreshMenu()
        }
        let card = PromptPanel(
            icon: .microphone,
            title: "Recording",
            message: events.isEmpty ? "Name this meeting." : "Name this meeting, or pick its calendar event.",
            fieldValue: recording.title,
            buttons: [
                ("Done", { [weak self] in apply(); self?.recordingCard = nil; self?.pendingTitle = nil }),
                ("Stop", { [weak self] in apply(); self?.recordingCard = nil; self?.pendingTitle = nil; self?.stopRecording() }),
            ],
            timeout: 15)
        if !events.isEmpty {
            card.addAccessory(EventMenu(events: events) { [weak card] event in
                picked = event
                card?.fieldText = event?.title ?? "Meeting"
                card?.holdTimeout(true)
            })
        }
        card.onTimeout = { [weak self] in apply(); self?.recordingCard = nil; self?.pendingTitle = nil }
        closeRecordingCard()
        recordingCard = card
        // Stopped from the menu with the card up: what it shows is kept.
        pendingTitle = apply
        card.show()
    }

    @objc private func recordFromDock(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(RecordMode.init(rawValue:)) else { return }
        recordNow(.menu(mode))
    }

    /// The menu bar and the Dock: a note in the notes window, whether or not a recording is running.
    @objc private func newNote() {
        NotesWindowController.shared.newNote(nil)
    }

    /// The global shortcut and the notes window's Record / Stop button; the window's menu items only start.
    private func toggleRecording(_ entry: RecordEntry) {
        if recording != nil {
            if case .menu = entry { return }
            stopRecording()
        } else {
            recordNow(entry)
        }
    }

    @objc private func stopRecording() {
        stop(byHand: true)
    }

    private func toggleMute() {
        guard let recording else { return }
        recording.micMuted.toggle()
        refreshMenu()
    }

    private func stop(byHand: Bool) {
        guard let finished = recording else { return }
        if recordingCard != nil { pendingTitle?() }
        pendingTitle = nil
        recording = nil
        enqueue(LiveMeeting(
            id: finished.id, title: finished.title, app: finished.appName, startedAt: finished.startedAt, phase: .queued,
            mode: finished.mode))
        pushLive()
        closeStopPrompt()
        closeSameCallPrompt()
        closeRecordingCard()
        if byHand { detector.stoppedByHand(finished.appName, at: Date()) }
        refreshMenu()

        Task { @MainActor [weak self] in
            await finished.stop()
            self?.process(finished.folder, staged: true, screenError: finished.screenError)
        }
    }

    private func discardRecording() {
        guard recording != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The sound and video recorded so far are deleted. This cannot be undone."
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        // The recording may have stopped by itself while the alert was up.
        guard alert.runModal() == .alertFirstButtonReturn, let discarded = recording else { return }
        recording = nil
        pushLive()
        closeStopPrompt()
        closeSameCallPrompt()
        closeRecordingCard()
        if let app = discarded.appName { detector.decline(app, at: Date()) }
        refreshMenu()
        Task { @MainActor in
            await discarded.stop()
            try? FileManager.default.removeItem(at: discarded.folder)
        }
    }

    private func closeRecordingCard() {
        recordingCard?.close()
        recordingCard = nil
        pendingTitle = nil
    }

    /// The notes window lists every live meeting: the recording, then the transcriber's jobs in order.
    private func pushLive() {
        let now = recording.map { recording in
            LiveMeeting(
                id: recording.id, title: recording.title, app: recording.appName, startedAt: recording.startedAt,
                phase: .recording(levels: { [weak recording] in recording?.levels ?? (0, 0) }), mode: recording.mode)
        }
        NotesWindowController.shared.setLive([now].compactMap { $0 } + queue.all)
    }

    /// Counts a job for the transcriber; the caller then hands it to `process`. With nothing ahead it shows as
    /// transcribing straight away, while its video is combined, else as waiting.
    private func enqueue(_ meeting: LiveMeeting?) {
        if let meeting { queue.add(meeting, next: transcribing == 0) }
        transcribing += 1
    }

    private func enqueue(folder: URL) {
        enqueue(Workspace.readMeta(folder).map {
            LiveMeeting(
                id: $0.id, title: $0.title, app: $0.app, startedAt: $0.startedAt, phase: .queued, mode: $0.recordMode)
        })
    }

    private func transcriptionStarted(_ meta: MeetingMeta?) {
        guard let meta else { return }
        queue.started(LiveMeeting(
            id: meta.id, title: meta.title, app: meta.app, startedAt: meta.startedAt, phase: .queued, mode: meta.recordMode))
        pushLive()
        menuBar.update()
    }

    private func transcriptionProgress(_ progress: Double, id: String) {
        guard queue.progress(progress, id: id) else { return }
        pushLive()
        menuBar.update()
    }

    /// Recordings left in staging by a quit or crash: repair, move in and transcribe them.
    private func recoverStaged() {
        let staged = (try? FileManager.default.contentsOfDirectory(
            at: Workspace.staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in staged {
            guard let meta = Workspace.readMeta(folder) else { continue }
            // A note caught between being written and moved in has nothing to transcribe.
            if Workspace.isNote(folder, meta: meta) {
                _ = try? Workspace.moveIn(folder)
                continue
            }
            enqueue(folder: folder)
            process(folder, staged: true, recovered: true)
        }
        pushLive()
    }

    /// Meetings whose transcription was cut off by a quit: transcribe them again.
    private func resumeTranscripts() {
        for (folder, meta) in Workspace.meetings() where Self.awaitsTranscript(folder, meta: meta) {
            enqueue(folder: folder)
            process(folder, staged: false)
        }
        pushLive()
    }

    /// Tracks on disk and no transcript yet. A note has no tracks, and a failed meeting is left for Try Again.
    static func awaitsTranscript(_ folder: URL, meta: MeetingMeta) -> Bool {
        let files = FileManager.default
        guard meta.transcriptError == nil, !files.fileExists(atPath: folder.appendingPathComponent("transcript.md").path)
        else { return false }
        return ["me.wav", "others.wav"].contains { files.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Video, then the move into the workspace, then the transcript. The caller has counted it in `transcribing`.
    private func process(_ start: URL, staged: Bool, recovered: Bool = false, screenError: Error? = nil) {
        transcribeQueue.async { [weak self] in
            // Current from the moment the transcriber takes it, video included, so the line never shows a gap.
            let taken = Workspace.readMeta(start)
            DispatchQueue.main.async { self?.transcriptionStarted(taken) }
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

            ModelStore.shared.waitForTranscriptionModels()
            let meta = Workspace.readMeta(folder)
            DispatchQueue.main.async { self?.transcriptionStarted(meta) }
            let result = Result {
                try Transcriber.transcribe(
                    folder: folder, title: meta?.title ?? folder.lastPathComponent, startedAt: meta?.startedAt ?? Date(),
                    id: meta?.id,
                    progress: { value in
                        guard let id = meta?.id else { return }
                        DispatchQueue.main.async { self?.transcriptionProgress(value, id: id) }
                    })
            }
            if let id = meta?.id {
                let current = Workspace.folder(id: id) ?? folder
                _ = try? Workspace.updateMeta(current) {
                    switch result {
                    // Not kept, so the next launch tries again.
                    case .failure(let error as TranscriptionError) where error.needsModels: $0.transcriptError = nil
                    case .failure(let error): $0.transcriptError = error.localizedDescription
                    case .success: $0.transcriptError = nil
                    }
                }
                Sync.shared.enqueue(meetingID: id)
                // Pictures for the summary, in the background; a summary started meanwhile waits for them.
                if case .success = result { FrameExtractor.shared.start(meetingID: id) }
            }
            Workspace.notifyChanged()
            DispatchQueue.main.async { self?.transcribed(result, folder: folder, meta: meta, problems: problems) }
        }
    }

    private func transcribed(_ result: Result<URL, Error>, folder: URL, meta: MeetingMeta?, problems: [String]) {
        transcribing -= 1
        queue.finished(meta?.id ?? Workspace.readMeta(folder)?.id)
        if transcribing == 0 { queue.clear() }
        pushLive()
        refreshMenu()
        let title = meta?.title ?? folder.lastPathComponent
        let panel: PromptPanel
        switch result {
        case .success:
            // Read again: the page may have been marked confidential while the transcript was made.
            let current = meta.flatMap { Workspace.folder(id: $0.id) }.flatMap(Workspace.readMeta) ?? meta
            let confidential = current?.confidential == true
            let summaries = Settings.summaryProvider != .off
            var notes = problems
            var buttons: [(String, () -> Void)] = []
            if let id = meta?.id {
                buttons.append(("Open", { NotesWindowController.shared.show(meetingID: id) }))
                if summaries && Settings.autoSummarise && !confidential {
                    notes.insert("Summarising with \(SummaryModel.current.label)…", at: 0)
                    summarise(id, model: SummaryModel.current, force: false)
                } else if summaries {
                    if confidential { notes.insert("Confidential: not sent for summary.", at: 0) }
                    buttons.append((confidential ? "Summarise Anyway" : "Summarise", { [weak self] in
                        self?.summarise(id, model: SummaryModel.current, force: true)
                    }))
                }
            } else {
                buttons.append(("Show in Finder", { NSWorkspace.shared.open(folder) }))
            }
            buttons.append(("Close", {}))
            let length = current.flatMap(Self.duration).map { " · \($0)" } ?? ""
            panel = PromptPanel(
                icon: .transcript, title: "Transcript ready", message: title + length,
                detail: notes.isEmpty ? nil : notes.joined(separator: "\n"), buttons: buttons, timeout: 60)
        case .failure(let error):
            if let error = error as? TranscriptionError, error.needsModels, let id = meta?.id {
                waitingForModels.insert(id)
                retryWaitingForModels()
            }
            let tail = String(error.localizedDescription.suffix(300))
            panel = PromptPanel(
                icon: .warning, title: "Transcription failed", message: "\(title) · the audio is saved",
                detail: (problems + [tail]).joined(separator: " "), monospacedDetail: true,
                buttons: [
                    ("Try Again", { [weak self] in self?.retranscribe(folder) }),
                    ("Show Recording", { NSWorkspace.shared.open(folder) }),
                ], timeout: 0)
        }
        panel.show()
    }

    private func retranscribe(_ folder: URL) {
        let current = Workspace.readMeta(folder).flatMap { Workspace.folder(id: $0.id) } ?? folder
        guard FileManager.default.fileExists(atPath: current.path) else { return }
        enqueue(folder: current)
        pushLive()
        refreshMenu()
        process(current, staged: current.path.hasPrefix(Workspace.staging.path))
    }

    /// "52 min", "1 h 12 min".
    static func duration(_ meta: MeetingMeta) -> String? {
        guard let end = meta.endedAt else { return nil }
        let minutes = max(1, Int((end.timeIntervalSince(meta.startedAt) / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h" + (minutes % 60 == 0 ? "" : " \(minutes % 60) min")
    }

    /// Meetings that failed for want of the speech model, once the model is in.
    private func retryWaitingForModels() {
        guard !waitingForModels.isEmpty, !ModelStore.shared.isDownloading,
              !ModelStore.missing.contains(where: \.transcription)
        else { return }
        for id in waitingForModels {
            guard let folder = Workspace.folder(id: id),
                  !FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path)
            else { continue }
            enqueue(folder: folder)
            process(folder, staged: false)
        }
        waitingForModels = []
        pushLive()
        refreshMenu()
    }

    // MARK: Summary

    /// `force` sends a meeting marked confidential; only an explicit request for that one meeting passes it.
    private func summarise(_ id: String, model: SummaryModel, force: Bool) {
        guard !summarisingIDs.contains(id), let folder = Workspace.folder(id: id) else { return }
        summarisingIDs.insert(id)
        summarisingTitles[id] = Workspace.readMeta(folder)?.title
        summarising += 1
        NotesWindowController.shared.setBusy(id, true)
        refreshMenu()

        summaryQueue.async { [weak self] in
            // Looked up again here: the meeting may have been renamed while waiting.
            let result = Result { () throws -> URL in
                guard let folder = Workspace.folder(id: id) else { throw CocoaError(.fileNoSuchFile) }
                return try Summarizer.summarize(folder: folder, model: model, force: force)
            }
            if case .success = result { Sync.shared.enqueue(meetingID: id) }
            let title = Workspace.folder(id: id).flatMap(Workspace.readMeta)?.title ?? "Meeting"
            DispatchQueue.main.async {
                guard let self else { return }
                self.summarising -= 1
                self.summarisingIDs.remove(id)
                self.summarisingTitles[id] = nil
                NotesWindowController.shared.setBusy(id, false)
                self.refreshMenu()
                self.summarised(result, id: id, title: title, model: model, force: force)
            }
        }
    }

    private func summarised(_ result: Result<URL, Error>, id: String, title: String, model: SummaryModel, force: Bool) {
        let panel: PromptPanel
        let open: (String, () -> Void) = ("Open", { NotesWindowController.shared.show(meetingID: id) })
        switch result {
        case .success(let url):
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let digest = Summarizer.digest(text)
            let counts = [
                SettingsModel.count(digest.decisions, "decision"), SettingsModel.count(digest.actions, "action item"),
            ].joined(separator: " · ")
            let briefings = BriefingCenter.shared
            // Under "After every summary" the new summary gets its briefing now, without playing it.
            if briefings.mode == .after { briefings.make(id, autoplay: false) }
            var card: BriefingCard?
            let listen: [(String, () -> Void)] = briefings.mode == .off ? [] : [("Listen", { card?.pressed() })]
            panel = PromptPanel(
                icon: .summary, title: "Summary ready", message: "\(title) · \(counts)", detail: digest.firstAction,
                detailLines: 2,
                buttons: [open] + listen + [
                    ("Copy", {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }),
                ], closable: true, timeout: 60)
            if !listen.isEmpty { card = BriefingCard(panel: panel, meetingID: id, listenIndex: 1) }
        case .failure(let error as SummaryError) where error.reason == .confidential:
            panel = PromptPanel(
                icon: .summary, title: "Not sent for summary", message: title, detail: error.message,
                buttons: [
                    ("Summarise Anyway", { [weak self] in self?.summarise(id, model: model, force: true) }),
                    ("Close", {}),
                ], timeout: 30)
        case .failure(let error as SummaryError) where error.reason == .off:
            panel = PromptPanel(
                icon: .summary, title: "Summaries are off", message: title, detail: error.message,
                buttons: [("Open Settings", { SettingsWindowController.shared.show(pane: .summary) }), ("Close", {})],
                timeout: 30)
        case .failure(let error):
            panel = PromptPanel(
                icon: .warning, title: "Summary failed", message: title,
                detail: String(error.localizedDescription.suffix(300)), monospacedDetail: true,
                buttons: [
                    ("Try Again", { [weak self] in self?.summarise(id, model: model, force: force) }),
                    ("Close", {}),
                ], timeout: 0)
        }
        panel.show()
    }

    @objc private func summariseLast() {
        guard let last = Self.lastTranscribed(Workspace.meetings()) else { return }
        summarise(last.meta.id, model: SummaryModel.current, force: false)
    }

    /// Summarise Last Meeting: the newest folder with a transcript, so notes and recordings still being transcribed
    /// are passed over.
    static func lastTranscribed(_ meetings: [(folder: URL, meta: MeetingMeta)]) -> (folder: URL, meta: MeetingMeta)? {
        meetings.first { FileManager.default.fileExists(atPath: $0.folder.appendingPathComponent("transcript.md").path) }
    }

    // MARK: Menu

    private func refreshMenu() {
        let briefings = BriefingCenter.shared
        briefings.setRecording(recording != nil)
        MicMute.shared.show(recording?.micMuted ?? false)
        if let recording {
            glyph.start(startedAt: recording.startedAt) { [weak recording] in recording?.levels ?? (0, 0) }
        } else {
            glyph.stop()
            if transcribing + summarising > 0 {
                statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Minutes")
            }
        }
        var briefing: BriefingMenuEntry?
        if briefings.mode != .off {
            let latest = briefings.latest()
            briefing = BriefingMenuEntry(
                playing: briefings.isPlaying,
                subtitle: latest.map { "\($0.title) · \(BriefingCenter.clock($0.duration))" },
                enabled: briefings.isPlaying || (latest != nil && recording == nil))
        }
        menuBar.rebuild(
            recording: recording != nil,
            canDownloadModels: !ModelStore.shared.isDownloading && !ModelStore.missing.isEmpty,
            shortcut: Settings.recordShortcut, briefing: briefing, muted: recording?.micMuted ?? false)
    }

    private func briefingFailed(_ error: Error) {
        PromptPanel(
            icon: .warning, title: "Briefing failed", message: "The spoken briefing could not be made",
            detail: String(error.localizedDescription.suffix(300)), monospacedDetail: true,
            buttons: [("Close", {})], timeout: 30
        ).show()
    }

    private var menuStatus: MenuBarStatus {
        let transcription = transcribing > 0 ? transcriptionLine() : nil
        if let recording {
            let label = [recording.appName ?? recording.title, recording.mode.name,
                         Self.clock(Date().timeIntervalSince(recording.startedAt))].joined(separator: " · ")
            // The transcript being made stays in view under the recording.
            let note = transcription.map { [$0.label, $0.waiting].compactMap { $0 }.joined(separator: "\n") }
            return .recording(
                label: label, mode: recording.mode, levels: { [weak recording] in recording?.levels ?? (0, 0) }, note: note)
        }
        if let briefing = BriefingCenter.shared.menuStatus { return briefing }
        if let transcription {
            return .transcribing(label: transcription.label, progress: transcription.progress, note: transcription.waiting)
        }
        if case .downloading(let percent) = ModelStore.shared.state {
            return .waiting(label: "Downloading speech models · \(percent)%", progress: Double(percent) / 100)
        }
        if summarising > 0 {
            let title = summarisingTitles.values.first.map { " \($0)" } ?? ""
            return .waiting(label: "Summarising\(title)…")
        }
        if case .failed(let message) = ModelStore.shared.state {
            return .waiting(label: "Waiting for a meeting", note: "Model download failed: \(message)")
        }
        return .waiting(label: "Waiting for a meeting", note: Sync.shared.status)
    }

    /// "Transcribing Sprint review · 52%" and "1 more meeting waiting". Jobs whose meta could not be read are counted
    /// but not listed.
    private func transcriptionLine() -> (label: String, progress: Double?, waiting: String?) {
        var progress: Double?
        if case .transcribing(let value) = queue.current?.phase { progress = value }
        let percent = progress.map { " · \(Int($0 * 100))%" } ?? ""
        let waiting = max(transcribing - 1, queue.waiting.count)
        return ("Transcribing \(queue.current?.title ?? "meeting")\(percent)", progress,
                waiting > 0 ? "\(SettingsModel.count(waiting, "more meeting", "more meetings")) waiting" : nil)
    }

    /// "12:41", or "1:02:05" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    @objc private func openNotes() {
        NotesWindowController.shared.show()
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Workspace.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Workspace.root)
    }

    // MARK: Dock

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openNotes() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        Self.dockMenu(recording: recording != nil, target: self)
    }

    static func dockMenu(recording: Bool, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        if recording {
            menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "").target = target
        } else {
            MenuBarMenu.startItems(target: target, action: #selector(recordFromDock(_:))).forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "").target = target
        menu.addItem(withTitle: "Summarise Last Meeting", action: #selector(summariseLast), keyEquivalent: "").target = target
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Minutes", action: #selector(VersionsWindowController.showVersions), keyEquivalent: "")
            .target = VersionsWindowController.shared
        return menu
    }

    // MARK: Misc

    private func showAlert(_ title: String, _ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
