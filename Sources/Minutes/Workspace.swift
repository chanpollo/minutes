import Foundation

/// meta.json in each meeting folder. The folder name follows the title, so jobs keep `id` and look the folder up again.
struct MeetingMeta: Codable {
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var app: String?
    var bundleID: String?
    // Written when recording starts; meetings from before modes have none and recorded the screen.
    var mode: RecordMode?
    // Names on the calendar event, organiser first, without the user.
    var attendees: [String]?
    // The calendar event was chosen by hand among those on at the start, so a summary never picks another.
    var eventPicked: Bool?
    // Seconds from the start of the WAVs to the first video frame; kept so a recording finished after a crash can still be muxed.
    var videoOffset: TimeInterval?
    // Set when transcription failed, so launch does not retry it every time.
    var transcriptError: String?
    var summaryModel: String?
    var summarizedAt: Date?
    var drive: DriveState?
    var sync: FolderSyncState?
    var groupID: String?
    // Not sent for summary unless the user overrides it for this meeting.
    var confidential: Bool?
    // The summary was sent although the meeting is confidential, on the user's word; marking it again clears this.
    var sentAnyway: Bool?
    var videoDeletedAt: Date?
    var audioDeletedAt: Date?
    // Sidebar only: pinned above the days, or moved out of the lists into Archived. Archiving clears the pin.
    var pinnedAt: Date?
    var archivedAt: Date?
    var briefing: BriefingInfo?
    // Made with New Note, notes first; stays set when a recording is made into it later.
    var note: Bool?

    var recordMode: RecordMode { mode ?? .screen }

    /// A note nothing has been recorded into: a recording sets `mode`.
    var isNote: Bool { note == true && mode == nil }
}

/// A user-made group of meetings, kept in groups.json at the workspace root.
struct MeetingGroup: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct DriveState: Codable {
    var folderID: String?
    var folderName: String?
    // The group whose Drive folder holds the meeting's folder; nil for Minutes itself.
    var groupID: String?
    // The frames/ sub-folder, made when the summary or notes first show a picture.
    var framesFolderID: String?
    // attachments/, made when notes.md first shows a picture of the user's own.
    var attachmentsFolderID: String?
    var files: [String: DriveFile] = [:]
}

struct DriveFile: Codable {
    var id: String
    var size: Int
    var modified: Date
}

extension Notification.Name {
    /// Posted on the main queue after a meeting folder is added, renamed or gains a file.
    static let meetingsChanged = Notification.Name("MinutesMeetingsChanged")
}

/// The folder the user picked for meetings, one sub-folder per meeting.
enum Workspace {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Meetings")
    // Recordings are written here and moved into the workspace when finished, so a synced folder never sees half-written files.
    nonisolated(unsafe) static var staging = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Minutes/Recording")

    private static let rootKey = "workspacePath"
    private static let lock = NSLock()

    static var root: URL {
        get { UserDefaults.standard.string(forKey: rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultRoot }
        set { UserDefaults.standard.set(newValue.path, forKey: rootKey) }
    }

    static func folderName(title: String, startedAt: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        return "\(stamp.string(from: startedAt)) \(cleanTitle(title))"
    }

    static func cleanTitle(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Meeting" : String(cleaned.prefix(80))
    }

    /// `name` in `directory`, or `name 2`, `name 3`… when taken.
    static func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(n)")
            n += 1
        }
        return candidate
    }

    /// Meeting folders under the workspace, newest first.
    static func meetings() -> [(folder: URL, meta: MeetingMeta)] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return folders
            .compactMap { folder in readMeta(folder).map { (folder, $0) } }
            .sorted { $0.meta.startedAt > $1.meta.startedAt }
    }

    static func folder(id: String) -> URL? {
        meetings().first { $0.meta.id == id }?.folder
    }

    static func readMeta(_ folder: URL) -> MeetingMeta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
        return try? decoder.decode(MeetingMeta.self, from: data)
    }

    static func writeMeta(_ meta: MeetingMeta, to folder: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Read-modify-write under one lock; summary and Drive upload both touch meta.json.
    @discardableResult
    static func updateMeta(_ folder: URL, _ change: (inout MeetingMeta) -> Void) throws -> MeetingMeta {
        lock.lock()
        defer { lock.unlock() }
        guard var meta = readMeta(folder) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.appendingPathComponent("meta.json").path])
        }
        change(&meta)
        try encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        return meta
    }

    /// Moves a finished recording from staging into the workspace. A recording made into a note joins the note's
    /// folder instead, which keeps its name; the start becomes the recording's. A fresh note has no mode, so it skips
    /// the lookup, which reads every meta.json.
    static func moveIn(_ staged: URL) throws -> URL {
        guard let meta = readMeta(staged) else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: staged.path]) }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if meta.note == true, meta.mode != nil, let note = folder(id: meta.id) {
            for file in try fm.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            where file.lastPathComponent != "meta.json" {
                let target = note.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: file, to: target)
            }
            try updateMeta(note) {
                $0.app = meta.app
                $0.bundleID = meta.bundleID
                $0.mode = meta.mode
                $0.startedAt = meta.startedAt
                $0.endedAt = meta.endedAt
                $0.videoOffset = meta.videoOffset
                if meta.confidential == true { $0.confidential = true }
            }
            try? fm.removeItem(at: staged)
            notifyChanged()
            return note
        }
        let target = uniqueURL(in: root, name: folderName(title: meta.title, startedAt: meta.startedAt))
        try fm.moveItem(at: staged, to: target)
        notifyChanged()
        return target
    }

    /// New Note: an empty note dated now, made in staging and moved in like a recording.
    static func makeNote(groupID: String? = nil, now: Date = Date()) throws -> (folder: URL, meta: MeetingMeta) {
        var meta = MeetingMeta(id: UUID().uuidString, title: "Untitled", startedAt: now, endedAt: now, note: true)
        meta.groupID = groupID
        let staged = staging.appendingPathComponent(meta.id)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try writeMeta(meta, to: staged)
        try Data().write(to: staged.appendingPathComponent("notes.md"))
        return (try moveIn(staged), meta)
    }

    /// `meta.isNote` and nothing recorded on disk either: the page, the row and the command line treat it as a note.
    static func isNote(_ folder: URL, meta: MeetingMeta) -> Bool {
        guard meta.isNote else { return false }
        let exists = { (name: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        return !exists("transcript.md") && !exists("meeting.mp4") && AudioTracks.existing(in: folder).isEmpty
    }

    /// Renames the meeting and its folder, and the title line of its transcript and summary; returns the new folder.
    static func rename(_ folder: URL, to title: String) throws -> URL {
        let old = readMeta(folder)?.title
        let meta = try updateMeta(folder) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = folderName(title: meta.title, startedAt: meta.startedAt)
        var target = folder
        if name != folder.lastPathComponent {
            target = uniqueURL(in: folder.deletingLastPathComponent(), name: name)
            try FileManager.default.moveItem(at: folder, to: target)
        }
        if let old, old != meta.title { retitle(target, from: old, to: meta.title) }
        CommentFile.refreshMarkdown(target)
        notifyChanged()
        return target
    }

    /// Rewrites the first line of transcript.md and summary.md when it is still `# <old>`; a header the user changed
    /// by hand is left alone.
    static func retitle(_ folder: URL, from old: String, to new: String) {
        for name in ["transcript.md", "summary.md"] {
            let url = folder.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8), let changed = retitled(text, from: old, to: new)
            else { continue }
            try? changed.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// `text` with its header changed, or nil when the header is not `# old`. The body is kept byte for byte.
    static func retitled(_ text: String, from old: String, to new: String) -> String? {
        let header = "# \(old)"
        guard text == header || text.hasPrefix(header + "\n") || text.hasPrefix(header + "\r\n") else { return nil }
        return "# \(new)" + text.dropFirst(header.count)
    }

    private static var groupsURL: URL { root.appendingPathComponent("groups.json") }

    static func groups() -> [MeetingGroup] {
        guard let data = try? Data(contentsOf: groupsURL) else { return [] }
        return (try? decoder.decode([MeetingGroup].self, from: data)) ?? []
    }

    static func saveGroups(_ groups: [MeetingGroup]) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(groups).write(to: groupsURL, options: .atomic)
        notifyChanged()
    }

    static func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .meetingsChanged, object: nil) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
