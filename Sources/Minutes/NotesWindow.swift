import AppKit
import AVFoundation
import SwiftUI

/// The meetings window: list by day, one page per meeting, notes.md beside it.
final class NotesWindowController: NSObject, NSWindowDelegate {
    static let shared = NotesWindowController()

    var onSummarise: ((_ meetingID: String, _ model: SummaryModel) -> Void)?
    var onChanged: ((_ meetingID: String) -> Void)?

    private var window: NSWindow?
    private let store = NotesStore()

    private override init() {
        super.init()
        store.onSummarise = { [weak self] id, model in self?.onSummarise?(id, model) }
        store.onChanged = { [weak self] id in self?.onChanged?(id) }
        store.onError = { [weak self] error in self?.present(error) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
    }

    func show(meetingID: String? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        store.open(selecting: meetingID)
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.makeMainMenu() }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func setBusy(_ meetingID: String, _ busy: Bool) {
        if Thread.isMainThread {
            store.setBusy(meetingID, busy)
        } else {
            DispatchQueue.main.async { self.store.setBusy(meetingID, busy) }
        }
    }

    // The model can be changed elsewhere, e.g. on the "Transcript ready" panel.
    func windowDidBecomeKey(_ notification: Notification) {
        store.syncModel()
    }

    func windowWillClose(_ notification: Notification) {
        store.close()
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func willTerminate() {
        store.saveNotes()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Minutes"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingController(rootView: NotesRootView(store: store))
        // Otherwise the window snaps to the SwiftUI ideal size.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.setContentSize(NSSize(width: 1100, height: 720))
        if !window.setFrameUsingName("NotesWindow") { window.center() }
        window.setFrameAutosaveName("NotesWindow")
        return window
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // The app has no menu bar of its own; text fields need Edit for copy, paste and undo shortcuts.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Quit Minutes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for submenu in [app, edit, window] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return main
    }
}

struct MeetingItem: Identifiable {
    let folder: URL
    let meta: MeetingMeta
    var id: String { meta.id }
}

struct MeetingPage {
    enum Transcript {
        case lines([TranscriptLine])
        case noSpeech, pending, missing

        var isPending: Bool {
            if case .pending = self { return true }
            return false
        }
    }

    let item: MeetingItem
    let media: MediaPlayer.Source
    let summary: [SummaryBlock]?
    let transcript: Transcript
}

final class NotesStore: ObservableObject {
    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    @Published private(set) var meetings: [MeetingItem] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var page: MeetingPage?
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var notes = ""
    @Published private(set) var model = SummaryModel.current
    @Published var query = ""
    @Published var tab = Tab.summary

    let player = MediaPlayer()
    var onSummarise: ((String, SummaryModel) -> Void)?
    var onChanged: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private var isOpen = false
    private var notesID: String?
    private var savedNotes = ""
    private var pendingSave: DispatchWorkItem?
    private var transcripts: [String: String] = [:]

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(meetingsChanged), name: .meetingsChanged, object: nil)
    }

    func open(selecting id: String?) {
        isOpen = true
        reload(preferring: id)
    }

    func close() {
        saveNotes()
        isOpen = false
        player.unload()
    }

    @objc private func meetingsChanged() {
        if isOpen { reload() }
    }

    func reload(preferring preferred: String? = nil) {
        syncModel()
        meetings = Workspace.meetings().map { MeetingItem(folder: $0.folder, meta: $0.meta) }
        transcripts = [:]
        let ids = Set(meetings.map(\.id))
        let target = [preferred, selectedID].compactMap { $0 }.first(where: ids.contains) ?? meetings.first?.id
        if target != selectedID {
            select(target)
        } else {
            loadPage()
        }
    }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        saveNotes()
        selectedID = id
        loadPage()
        loadNotes()
    }

    func item(_ id: String) -> MeetingItem? {
        meetings.first { $0.id == id }
    }

    private func loadPage() {
        page = selectedID.flatMap(item).map(Self.makePage)
        let media = page?.media ?? .none
        if isOpen, media != player.source { player.load(media) }
    }

    private static func makePage(_ item: MeetingItem) -> MeetingPage {
        let file = { (name: String) in item.folder.appendingPathComponent(name) }
        let exists = { (name: String) in FileManager.default.fileExists(atPath: file(name).path) }

        let wavs = ["me.wav", "others.wav"].filter(exists).map(file)
        let media: MediaPlayer.Source = exists("meeting.mp4") ? .video(file("meeting.mp4")) : wavs.isEmpty ? .none : .audio(wavs)

        let summary = (try? String(contentsOf: file("summary.md"), encoding: .utf8)).map(SummaryMarkdown.parse)

        let transcript: MeetingPage.Transcript
        if let text = try? String(contentsOf: file("transcript.md"), encoding: .utf8) {
            let parsed = TranscriptParser.parse(text)
            transcript = parsed.isEmpty ? .noSpeech : .lines(parsed)
        } else {
            // No way to see the job queue from here; a recent recording with audio is most likely still being transcribed.
            let recent = Date().timeIntervalSince(item.meta.endedAt ?? item.meta.startedAt) < 3 * 3600
            transcript = !wavs.isEmpty && recent ? .pending : .missing
        }
        return MeetingPage(item: item, media: media, summary: summary, transcript: transcript)
    }

    // MARK: Search

    func matches(_ item: MeetingItem) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if item.meta.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        return transcriptText(item).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func transcriptText(_ item: MeetingItem) -> String {
        if let cached = transcripts[item.id] { return cached }
        let text = (try? String(contentsOf: item.folder.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        transcripts[item.id] = text
        return text
    }

    // MARK: Actions

    /// Returns false when the rename failed, so the title field can revert.
    func rename(_ id: String, to title: String) -> Bool {
        guard let item = item(id) else { return false }
        // Focus loss and the field going away can both commit the same edit.
        guard title.trimmingCharacters(in: .whitespacesAndNewlines) != item.meta.title else { return true }
        do {
            _ = try Workspace.rename(item.folder, to: title)
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

    func syncModel() {
        if model != SummaryModel.current { model = SummaryModel.current }
    }

    func summarise(with choice: SummaryModel? = nil) {
        if let choice { SummaryModel.current = choice }
        syncModel()
        guard let id = selectedID, !busy.contains(id), let onSummarise else { return }
        // Marked now so a second click cannot start another job before the caller's setBusy arrives.
        busy.insert(id)
        onSummarise(id, model)
    }

    func setBusy(_ id: String, _ isBusy: Bool) {
        if isBusy {
            busy.insert(id)
        } else {
            busy.remove(id)
            if isOpen { reload() }
        }
    }

    // MARK: Notes

    private func loadNotes() {
        notesID = selectedID
        let text = selectedID.flatMap(item).flatMap {
            try? String(contentsOf: $0.folder.appendingPathComponent("notes.md"), encoding: .utf8)
        } ?? ""
        notes = text
        savedNotes = text
    }

    func editNotes(_ text: String) {
        guard text != notes else { return }
        notes = text
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.saveNotes() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: save)
    }

    func saveNotes() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let id = notesID, notes != savedNotes, let folder = item(id)?.folder else { return }
        let url = folder.appendingPathComponent("notes.md")
        if notes.isEmpty, !FileManager.default.fileExists(atPath: url.path) {
            savedNotes = notes
            return
        }
        do {
            try notes.write(to: url, atomically: true, encoding: .utf8)
            savedNotes = notes
            onChanged?(id)
        } catch {
            onError?(error)
        }
    }
}

/// One player at a time: the selected meeting's video, or both WAVs mixed when there is no video.
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
    private(set) var source = Source.none

    private var observer: Any?
    private var generation = 0

    func load(_ source: Source) {
        unload()
        self.source = source
        let generation = self.generation
        switch source {
        case .none:
            return
        case .video(let url):
            attach(AVPlayerItem(url: url), generation: generation)
        case .audio(let urls):
            Task { @MainActor in
                let composition = await Self.mix(urls)
                self.attach(AVPlayerItem(asset: composition), generation: generation)
            }
        }
    }

    func unload() {
        generation += 1
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        source = .none
        isPlaying = false
        time = 0
        duration = 0
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, time >= duration - 0.25 { player.seek(to: .zero) }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: TimeInterval, play: Bool = false) {
        guard let player else { return }
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play {
            player.play()
            isPlaying = true
        }
    }

    private func attach(_ item: AVPlayerItem, generation: Int) {
        guard generation == self.generation else { return }
        let player = AVPlayer(playerItem: item)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self, weak player] time in
            guard let self, let player else { return }
            self.time = time.seconds
            self.isPlaying = player.timeControlStatus != .paused
        }
        self.player = player
        Task { @MainActor in
            guard let length = try? await item.asset.load(.duration), generation == self.generation else { return }
            self.duration = length.seconds.isFinite ? length.seconds : 0
        }
    }

    // Each WAV goes on its own composition track; AVPlayer mixes the tracks.
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
}

/// The markdown subset the summary prompt produces: headings, bullets, paragraphs and pipe tables.
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
            let row = raw.trimmingCharacters(in: .whitespaces)
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
            } else if blocks.isEmpty, paragraph.isEmpty, row.contains(" · Summarised by Claude") {
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

    /// `14:00 · 52 min · Google Meet`
    static func rowLine(_ meta: MeetingMeta) -> String {
        [formatter("HH:mm").string(from: meta.startedAt), minutes(meta).map { "\($0) min" }, meta.app]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// `Wed 28 Oct 2026 · 14:00–14:52 · 52 min · Google Meet`
    static func metaLine(_ meta: MeetingMeta) -> String {
        let clock = formatter("HH:mm")
        let span = clock.string(from: meta.startedAt) + (meta.endedAt.map { "–" + clock.string(from: $0) } ?? "")
        return [formatter("EEE d MMM yyyy").string(from: meta.startedAt), span, minutes(meta).map { "\($0) min" }, meta.app]
            .compactMap { $0 }.joined(separator: " · ")
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
