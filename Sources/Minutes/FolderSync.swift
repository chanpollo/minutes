import Foundation

/// meta.sync: where the meeting's copy sits in the synced folder and what was copied.
struct FolderSyncState: Codable {
    /// The synced folder (Settings.syncFolder) at the time; another folder starts over.
    var base: String
    /// Under <base>/Minutes: "<group>/<meeting folder>" or "<meeting folder>".
    var path: String
    var files: [String: SyncedFile] = [:]
}

struct SyncedFile: Codable {
    var size: Int
    var modified: Date
}

/// Mirrors meeting folders into <sync folder>/Minutes[/<group>]/<meeting folder> for a sync app (Google Drive for
/// desktop, iCloud Drive, OneDrive, Dropbox) to upload. Files arrive under a hidden name and are renamed into place,
/// so the app never sees half a file. One meeting at a time.
final class FolderSync {
    static let shared = FolderSync()

    static let folderName = "Minutes"
    static let partialSuffix = ".minutes-partial"

    enum Status: Equatable {
        case notSynced
        case synced(Date, meetings: Int)
        case copying(String)
        /// The folder is not there (sync app quit, drive unmounted); `waiting` meetings copy when it is back.
        case missing(waiting: Int)
        case noFolder
        case failed(String)

        /// For the menu bar: only what needs attention or is moving.
        var note: String? {
            switch self {
            case .copying(let title): "Syncing \(title)…"
            case .missing: "Sync folder not found"
            case .failed(let text): text
            default: nil
            }
        }
    }

    private struct FolderMissing: Error {}
    private struct Stopped: Error {}

    private let worker = DispatchQueue(label: "minutes.folder-sync", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var current: Status
    private var debounce: DispatchWorkItem?

    private static let lastSyncedKey = "syncLastSynced"
    private static let lastCountKey = "syncLastCount"

    private init() {
        let defaults = UserDefaults.standard
        if let date = defaults.object(forKey: Self.lastSyncedKey) as? Date {
            current = .synced(date, meetings: defaults.integer(forKey: Self.lastCountKey))
        } else {
            current = .notSynced
        }
        // Renames, group moves and new files only post meetingsChanged.
        NotificationCenter.default.addObserver(forName: .meetingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                if Settings.syncMode == .folder { self?.enqueuePending() }
            }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    var status: Status { lock.withLock { current } }

    // MARK: Queue

    func enqueue(meetingID: String) {
        schedule { self.pass(only: meetingID) }
    }

    /// Every meeting whose copy is missing or behind; meetings being transcribed wait until they are done.
    func enqueuePending() {
        schedule { self.pass(only: nil) }
    }

    /// Marked confidential while another sync, or none, is chosen: the copy in the folder still goes.
    func withdrawConfidential(meetingID: String) {
        worker.async {
            guard let folder = Sync.locate(meetingID), let meta = Workspace.readMeta(folder),
                  meta.confidential == true, meta.sync != nil else { return }
            try? self.withdraw(meta)
        }
    }

    /// Work already queued is dropped; a copy in progress ends after its current file.
    func stop() {
        lock.withLock { generation += 1 }
    }

    /// A different folder was chosen: its state starts empty.
    func forget() {
        stop()
        UserDefaults.standard.removeObject(forKey: Self.lastSyncedKey)
        UserDefaults.standard.removeObject(forKey: Self.lastCountKey)
        setStatus(.notSynced)
    }

    /// Blocks until queued work is done; for tests.
    func waitUntilIdle() {
        worker.sync {}
    }

    private func schedule(_ work: @escaping () -> Void) {
        let scheduled = lock.withLock { generation }
        worker.async {
            guard Settings.syncMode == .folder, !self.stopped(since: scheduled) else { return }
            work()
        }
    }

    private func stopped(since scheduled: Int) -> Bool {
        lock.withLock { generation != scheduled }
    }

    private func setStatus(_ status: Status) {
        let changed: Bool = lock.withLock {
            guard current != status else { return false }
            current = status
            return true
        }
        if case .synced(let date, let meetings) = status {
            UserDefaults.standard.set(date, forKey: Self.lastSyncedKey)
            UserDefaults.standard.set(meetings, forKey: Self.lastCountKey)
        }
        if changed { Sync.shared.notify() }
    }

    // MARK: Pass

    private func pass(only meetingID: String?) {
        let started = lock.withLock { generation }
        guard let path = Settings.syncFolder else { return setStatus(.noFolder) }
        let base = URL(fileURLWithPath: path, isDirectory: true)
        let meetings = Workspace.meetings()
        // With the folder away every copy looks missing, so count only what changed here.
        let waiting = { meetings.filter { Self.needsSync($0.folder, $0.meta, base: base, checkCopies: false) }.count }
        guard Self.isFolder(base) else { return setStatus(.missing(waiting: waiting())) }
        // One meeting's change looks at that meeting only; the full scan is for enqueuePending.
        let todo = meetings
            .filter { meetingID == nil ? !Housekeeping.isHeld($0.meta.id) : $0.meta.id == meetingID }
            .filter { Self.needsSync($0.folder, $0.meta, base: base) }
        var failure: String?
        for meeting in todo {
            guard !stopped(since: started) else { return }
            setStatus(.copying(meeting.meta.title))
            do {
                try sync(meetingID: meeting.meta.id, base: base, started: started)
            } catch is FolderMissing {
                return setStatus(.missing(waiting: waiting()))
            } catch is Stopped, is Sync.MeetingGone {
            } catch {
                failure = "Sync failed: \(error.localizedDescription)"
            }
        }
        guard !stopped(since: started) else { return }
        if let failure { return setStatus(.failed(failure)) }
        let copies = Workspace.meetings().filter { $0.meta.sync?.base == base.path }.count
        setStatus(.synced(Date(), meetings: copies))
    }

    /// `checkCopies` also looks for each copy there, so one deleted there is made again.
    static func needsSync(_ folder: URL, _ meta: MeetingMeta, base: URL, checkCopies: Bool = true) -> Bool {
        if meta.confidential == true { return meta.sync != nil }
        let names = Sync.fileNames(in: folder, meta: meta)
        guard let state = meta.sync, state.base == base.path else { return !names.isEmpty }
        if state.path != relativePath(folder, meta) { return true }
        let copy = destination(base).appendingPathComponent(state.path)
        return names.contains { name in
            guard let stamp = Sync.fileStamp(folder.appendingPathComponent(name)) else { return false }
            guard let record = state.files[name], record.size == stamp.size, record.modified == stamp.modified else { return true }
            return checkCopies && !FileManager.default.fileExists(atPath: copy.appendingPathComponent(name).path)
        }
    }

    static func destination(_ base: URL) -> URL {
        base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// "<group>/<meeting folder>", or just the folder outside a group or with one folder for all.
    static func relativePath(_ folder: URL, _ meta: MeetingMeta) -> String {
        [Sync.liveGroup(meta.groupID).map(groupFolder), folder.lastPathComponent]
            .compactMap { $0 }.joined(separator: "/")
    }

    /// No leading dots: ".." would leave Minutes/, and a hidden folder is skipped by some sync apps.
    static func groupFolder(_ group: MeetingGroup) -> String {
        let name = String(Workspace.cleanTitle(group.name).drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Group" : name
    }

    // MARK: One meeting

    private func sync(meetingID: String, base: URL, started: Int) throws {
        guard let folder = Sync.locate(meetingID), let meta = Workspace.readMeta(folder) else { return }
        if meta.confidential == true { return try withdraw(meta) }
        // Never make the synced folder itself: a missing one means its app is not running.
        guard Self.isFolder(base) else { throw FolderMissing() }
        let fm = FileManager.default
        let root = Self.destination(base)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var state = meta.sync.flatMap { $0.base == base.path ? $0 : nil } ?? FolderSyncState(base: base.path, path: Self.relativePath(folder, meta))
        let wanted = Self.relativePath(folder, meta)
        if state.path != wanted {
            let from = root.appendingPathComponent(state.path)
            let to = root.appendingPathComponent(wanted)
            if fm.fileExists(atPath: to.path) || !fm.fileExists(atPath: from.path) {
                // Something already has the new name, or the copy is gone: copy afresh there and leave the rest alone.
                state.files = [:]
            } else {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                Self.prune(from.deletingLastPathComponent(), within: root)
            }
            state.path = wanted
            let moved = state
            try Sync.record(meetingID) { $0.sync = moved }
        }

        let copy = root.appendingPathComponent(state.path, isDirectory: true)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        Self.removePartials(in: copy)
        for name in Sync.fileNames(in: folder, meta: meta) {
            guard !stopped(since: started) else { throw Stopped() }
            let source = folder.appendingPathComponent(name)
            let target = copy.appendingPathComponent(name)
            guard let stamp = Sync.fileStamp(source) else { continue }
            if let record = state.files[name], record.size == stamp.size, record.modified == stamp.modified,
               fm.fileExists(atPath: target.path) { continue }
            guard Self.isFolder(base) else { throw FolderMissing() }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.place(source, at: target)
            state.files[name] = SyncedFile(size: stamp.size, modified: stamp.modified)
            let copied = state
            try Sync.record(meetingID) { $0.sync = copied }
        }

        // A track compressed to FLAC after its WAV was copied: the WAV copy is now a duplicate.
        let stale = AudioTracks.names.map { "\($0).wav" }.filter { wav in
            state.files[wav] != nil && state.files[wav.replacingOccurrences(of: ".wav", with: ".flac")] != nil
                && !fm.fileExists(atPath: folder.appendingPathComponent(wav).path)
        }
        if !stale.isEmpty {
            for name in stale {
                try? fm.removeItem(at: copy.appendingPathComponent(name))
                state.files[name] = nil
            }
            let cleaned = state
            try Sync.record(meetingID) { $0.sync = cleaned }
        }
        if meta.sync == nil || meta.sync?.base != base.path {
            let placed = state
            try Sync.record(meetingID) { $0.sync = placed }
        }
    }

    /// Marked confidential after it was copied: the copy goes from the synced folder. An earlier folder that is away
    /// only holds back this meeting, which is tried again on the next pass.
    private func withdraw(_ meta: MeetingMeta) throws {
        guard let state = meta.sync else { return }
        let base = URL(fileURLWithPath: state.base, isDirectory: true)
        guard Self.isFolder(base) else {
            if state.base == Settings.syncFolder { throw FolderMissing() }
            return
        }
        let root = Self.destination(base)
        let copy = root.appendingPathComponent(state.path)
        if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
        Self.prune(copy.deletingLastPathComponent(), within: root)
        try Sync.record(meta.id) { $0.sync = nil }
    }

    // MARK: Deleting copies

    /// Clean-up deleted these files here; their copies go too. Kept in meta.sync when the folder is away, so the next
    /// clean-up tries again.
    func deleteCopies(meetingID: String, names: [String]) {
        guard !names.isEmpty else { return }
        schedule {
            guard let folder = Sync.locate(meetingID), let meta = Workspace.readMeta(folder), var state = meta.sync else { return }
            let base = URL(fileURLWithPath: state.base, isDirectory: true)
            guard Self.isFolder(base) else { return }
            let copy = Self.destination(base).appendingPathComponent(state.path)
            for name in names where state.files[name] != nil {
                let target = copy.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path), (try? FileManager.default.removeItem(at: target)) == nil { continue }
                state.files[name] = nil
            }
            let left = state
            try? Sync.record(meetingID) { $0.sync = left }
        }
    }

    /// The meeting was deleted here; its copy goes from the synced folder.
    func removeCopy(_ meta: MeetingMeta) {
        guard let state = meta.sync else { return }
        schedule {
            let base = URL(fileURLWithPath: state.base, isDirectory: true)
            guard Self.isFolder(base) else { return }
            let root = Self.destination(base)
            let copy = root.appendingPathComponent(state.path)
            try? FileManager.default.removeItem(at: copy)
            Self.prune(copy.deletingLastPathComponent(), within: root)
        }
    }

    // MARK: Files

    /// Copies to a hidden name beside the target, then renames it over the target in one step.
    static func place(_ source: URL, at target: URL) throws {
        let fm = FileManager.default
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent)\(partialSuffix)")
        try? fm.removeItem(at: temp)
        try fm.copyItem(at: source, to: temp)
        guard rename(temp.path, target.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path, NSUnderlyingErrorKey: POSIXError(code)])
        }
    }

    /// Left by a copy cut short (quit, crash).
    private static func removePartials(in folder: URL) {
        let fm = FileManager.default
        for dir in [folder, folder.appendingPathComponent(Frames.folderName), folder.appendingPathComponent(NotesAttachments.folderName)] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(partialSuffix) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// Removes `folder` and the empty folders above it, up to (not including) `root`.
    private static func prune(_ folder: URL, within root: URL) {
        let fm = FileManager.default
        var dir = folder.standardizedFileURL
        let top = root.standardizedFileURL.path
        while dir.path.hasPrefix(top + "/") {
            let left = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }
            guard left.isEmpty, (try? fm.removeItem(at: dir)) != nil else { return }
            dir = dir.deletingLastPathComponent()
        }
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
