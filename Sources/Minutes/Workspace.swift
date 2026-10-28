import Foundation

/// meta.json in each meeting folder. The folder name follows the title, so jobs keep `id` and look the folder up again.
struct MeetingMeta: Codable {
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var app: String?
    var bundleID: String?
    // Seconds from the start of the WAVs to the first video frame; kept so a recording finished after a crash can still be muxed.
    var videoOffset: TimeInterval?
    // Set when transcription failed, so launch does not retry it every time.
    var transcriptError: String?
    var summaryModel: String?
    var summarizedAt: Date?
    var drive: DriveState?
}

struct DriveState: Codable {
    var folderID: String?
    var folderName: String?
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
    static let staging = FileManager.default.homeDirectoryForCurrentUser
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

    /// Moves a finished recording from staging into the workspace.
    static func moveIn(_ staged: URL) throws -> URL {
        guard let meta = readMeta(staged) else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: staged.path]) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = uniqueURL(in: root, name: folderName(title: meta.title, startedAt: meta.startedAt))
        try FileManager.default.moveItem(at: staged, to: target)
        notifyChanged()
        return target
    }

    /// Renames the meeting and its folder; returns the new folder.
    static func rename(_ folder: URL, to title: String) throws -> URL {
        let meta = try updateMeta(folder) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = folderName(title: meta.title, startedAt: meta.startedAt)
        guard name != folder.lastPathComponent else { notifyChanged(); return folder }
        let target = uniqueURL(in: folder.deletingLastPathComponent(), name: name)
        try FileManager.default.moveItem(at: folder, to: target)
        notifyChanged()
        return target
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
