import AppKit
import Foundation

extension Notification.Name {
    /// Posted on the main queue when the sync mode, the folder or `FolderSync.shared.status` changes.
    static let syncStatusChanged = Notification.Name("MinutesSyncStatusChanged")
}

/// Hands meetings to whichever sync Settings choose: a folder another app syncs, or Google Drive signed in from Minutes.
/// Only one runs; switching stops the other and leaves its copies where they are.
final class Sync {
    static let shared = Sync()

    static let interval: TimeInterval = 6 * 3600

    private var timer: Timer?

    private init() {}

    var mode: Settings.SyncMode { Settings.syncMode }

    /// Launch: decides the mode once, then syncs what is behind and retries every few hours.
    func start() {
        Self.migrate(driveConnected: DriveSync.shared.isConnected)
        enqueuePending()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.enqueuePending() }
        timer?.tolerance = 60
    }

    /// Before Sync there was only Drive: a connected Drive keeps uploading, everyone else starts with Off.
    static func migrate(driveConnected: Bool) {
        guard !Settings.syncModeChosen else { return }
        Settings.syncMode = driveConnected ? .googleDrive : .off
    }

    func setMode(_ new: Settings.SyncMode) {
        guard new != Settings.syncMode else { return }
        Settings.syncMode = new
        if new != .folder { FolderSync.shared.stop() }
        if new != .googleDrive { DriveSync.shared.stop() }
        if new == .folder, Settings.syncFolder == nil { Settings.syncFolder = SyncPlaces.detect().first?.path }
        enqueuePending()
        notify()
    }

    func setFolder(_ path: String) {
        guard path != Settings.syncFolder else { return }
        FolderSync.shared.forget()
        Settings.syncFolder = path
        enqueuePending()
        notify()
    }

    func enqueue(meetingID: String) {
        switch mode {
        case .off: break
        case .folder: FolderSync.shared.enqueue(meetingID: meetingID)
        case .googleDrive: DriveSync.shared.enqueue(meetingID: meetingID)
        }
        // Only uploads follow the mode: a meeting marked confidential leaves both places whatever is chosen.
        if mode != .folder { FolderSync.shared.withdrawConfidential(meetingID: meetingID) }
        if mode != .googleDrive { DriveSync.shared.withdrawConfidential(meetingID: meetingID) }
    }

    func enqueuePending() {
        switch mode {
        case .off: break
        case .folder: FolderSync.shared.enqueuePending()
        case .googleDrive: DriveSync.shared.enqueuePending()
        }
    }

    /// Clean-up removed these files here; with "Delete there too" their copies go as well.
    func deleteCopies(meetingID: String, names: [String]) {
        switch mode {
        case .off: break
        case .folder: FolderSync.shared.deleteCopies(meetingID: meetingID, names: names)
        case .googleDrive: DriveSync.shared.deleteCopies(meetingID: meetingID, names: names)
        }
    }

    /// The meeting was moved to the Trash here.
    func meetingDeleted(_ meta: MeetingMeta) {
        guard Settings.deleteOnDrive else { return }
        switch mode {
        case .off: break
        case .folder: FolderSync.shared.removeCopy(meta)
        case .googleDrive: DriveSync.shared.trashMeeting(meta)
        }
    }

    /// A meeting deleted here was put back from the Trash.
    func meetingRestored(_ meta: MeetingMeta) {
        guard Settings.deleteOnDrive, mode == .googleDrive else { return }
        DriveSync.shared.untrashMeeting(meta)
    }

    /// One line for the menu bar, only when something needs attention or is moving.
    var status: String? {
        switch mode {
        case .off: nil
        case .folder: FolderSync.shared.status.note
        case .googleDrive: DriveSync.shared.status
        }
    }

    func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .syncStatusChanged, object: nil) }
    }

    // MARK: Files

    // briefing.m4a never leaves this Mac; only its script goes.
    static let textFiles = ["transcript.md", "summary.md", "notes.md", CommentFile.markdownName, Briefing.scriptName]

    /// What Settings send, as paths inside the meeting folder: the text files, the pictures the summary or notes show,
    /// and the video (or the audio tracks when there never was one). Nothing of a confidential meeting.
    static func fileNames(in folder: URL, meta: MeetingMeta) -> [String] {
        guard meta.confidential != true else { return [] }
        let exists = { (name: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        var names: [String] = []
        if Settings.driveUploadText {
            names = textFiles.filter(exists)
            names += pictures(in: folder).filter(exists)
        }
        if Settings.driveUploadMedia {
            if exists("meeting.mp4") {
                names.append("meeting.mp4")
            } else if meta.videoDeletedAt == nil {
                names += AudioTracks.existing(in: folder).map(\.lastPathComponent)
            }
        }
        return names
    }

    /// frames/… images linked from summary.md or notes.md, then the attachments/… notes.md shows, in order, once each.
    static func pictures(in folder: URL) -> [String] {
        Frames.referenced(in: folder) + NotesAttachments.referenced(inFolder: folder)
    }

    /// Size and modification time, at whole seconds as meta.json keeps them.
    static func fileStamp(_ url: URL) -> (size: Int, modified: Date)? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize, let date = values.contentModificationDate
        else { return nil }
        return (size, Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
    }

    /// The meeting's group when it still exists and Settings keep a folder per group.
    static func liveGroup(_ id: String?) -> MeetingGroup? {
        guard let id, Settings.syncFolderPerGroup else { return nil }
        return Workspace.groups().first { $0.id == id }
    }

    // MARK: Meta

    // A folder being renamed drops out of Workspace.meetings() for a moment; look again before calling it gone.
    static func locate(_ meetingID: String) -> URL? {
        for attempt in 0..<3 {
            if let folder = Workspace.folder(id: meetingID) { return folder }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return nil
    }

    struct MeetingGone: LocalizedError {
        var errorDescription: String? { "The meeting was removed while syncing" }
    }

    /// Writes to wherever the folder is now: a rename during a copy must not lose what was copied.
    static func record(_ meetingID: String, _ change: (inout MeetingMeta) -> Void) throws {
        var misses = 0
        while true {
            guard let folder = locate(meetingID) else { throw MeetingGone() }
            do {
                try Workspace.updateMeta(folder, change)
                return
            } catch where misses < 2 && locate(meetingID)?.standardizedFileURL != folder.standardizedFileURL {
                misses += 1 // Workspace.rename moves the folder outside the meta lock, so the read or the atomic write can miss it
            }
        }
    }
}

// MARK: - Places

/// A folder a sync app uploads, found on this Mac.
struct SyncPlace: Identifiable, Equatable {
    enum Kind { case googleDrive, iCloud, oneDrive, dropbox, cloud, other }

    let kind: Kind
    let name: String
    let detail: String
    let path: String

    var id: String { path }

    /// The app that syncs it, for "is it running?".
    var appName: String? {
        switch kind {
        case .googleDrive: "Google Drive"
        case .iCloud: "iCloud Drive"
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        case .cloud: name
        case .other: nil
        }
    }

    /// "…/My Drive/Minutes"; a folder picked by hand shows from the home folder.
    var shortDestination: String {
        switch kind {
        case .iCloud: "…/iCloud Drive/Minutes"
        case .other: (path as NSString).abbreviatingWithTildeInPath + "/Minutes"
        default: "…/\((path as NSString).lastPathComponent)/Minutes"
        }
    }

    /// Google Drive has no symbol and draws its own glyph.
    var symbol: String {
        switch kind {
        case .iCloud: "icloud"
        case .dropbox: "shippingbox"
        case .other: "folder"
        default: "cloud"
        }
    }
}

enum SyncPlaces {
    /// Detection reads folder names under here only; never writes.
    nonisolated(unsafe) static var home = FileManager.default.homeDirectoryForCurrentUser

    /// Google Drive, OneDrive, Dropbox and other File Provider apps under ~/Library/CloudStorage, then iCloud Drive.
    static func detect(home: URL = home) -> [SyncPlace] {
        let fm = FileManager.default
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let names = ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        var places: [SyncPlace] = []
        for name in names {
            let folder = storage.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let (app, account) = split(name)
            switch app {
            case "GoogleDrive":
                places.append(SyncPlace(
                    kind: .googleDrive, name: "Google Drive", detail: [account, "My Drive"].compactMap { $0 }.joined(separator: " · "),
                    path: folder.appendingPathComponent("My Drive").path))
            case "OneDrive":
                places.append(SyncPlace(kind: .oneDrive, name: "OneDrive", detail: account ?? "OneDrive", path: folder.path))
            case "Dropbox":
                places.append(SyncPlace(kind: .dropbox, name: "Dropbox", detail: account ?? "Dropbox", path: folder.path))
            default:
                places.append(SyncPlace(kind: .cloud, name: app, detail: account ?? app, path: folder.path))
            }
        }
        let legacyDropbox = home.appendingPathComponent("Dropbox")
        if !places.contains(where: { $0.kind == .dropbox }), fm.fileExists(atPath: legacyDropbox.appendingPathComponent(".dropbox").path) {
            places.append(SyncPlace(kind: .dropbox, name: "Dropbox", detail: "Dropbox", path: legacyDropbox.path))
        }
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            places.append(SyncPlace(kind: .iCloud, name: "iCloud Drive", detail: "iCloud Drive", path: iCloud.path))
        }
        let order: [SyncPlace.Kind] = [.googleDrive, .iCloud, .oneDrive, .dropbox, .cloud]
        return places.enumerated()
            .sorted { (order.firstIndex(of: $0.element.kind)!, $0.offset) < (order.firstIndex(of: $1.element.kind)!, $1.offset) }
            .map(\.element)
    }

    /// The detected place at `path`, or a hand-picked folder.
    static func place(at path: String, in places: [SyncPlace]) -> SyncPlace {
        places.first { $0.path == path }
            ?? SyncPlace(kind: .other, name: "Other folder", detail: (path as NSString).abbreviatingWithTildeInPath, path: path)
    }

    /// "GoogleDrive-nok@example.com" → ("GoogleDrive", "nok@example.com"); "Dropbox" → ("Dropbox", nil).
    static func split(_ name: String) -> (app: String, account: String?) {
        guard let dash = name.firstIndex(of: "-") else { return (name, nil) }
        let account = String(name[name.index(after: dash)...])
        return (String(name[..<dash]), account.isEmpty ? nil : account)
    }
}
