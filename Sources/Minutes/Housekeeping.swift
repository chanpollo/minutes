import Foundation

/// Deletes old videos and audio tracks as Settings say; never touches transcripts, summaries, notes, frames/ (pictures
/// stay when their video goes) or meta.json.
enum Housekeeping {
    struct Report {
        var videosDeleted = 0
        var audioDeleted = 0
        var bytesFreed: Int64 = 0
        /// Saved by turning WAV tracks into FLAC.
        var bytesCompressed: Int64 = 0
    }

    struct Policy {
        var keepVideoDays = Settings.keepVideoDays
        var keepAudioDays = Settings.keepAudioDays
        var compressAudio = Settings.compressAudio
        var deleteOnDrive = Settings.deleteOnDrive
    }

    static let interval: TimeInterval = 6 * 3600

    private static let queue = DispatchQueue(label: "minutes.housekeeping", qos: .utility)
    private static let lock = NSLock()
    // One pass at a time: the timer and Clean Up Now must not compress the same track twice.
    private static let passLock = NSLock()
    nonisolated(unsafe) private static var busy: [String: Int] = [:]
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// Runs now and then every few hours.
    static func start() {
        lock.withLock {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            // Wall time, so hours spent asleep count towards the next run.
            source.schedule(wallDeadline: .now() + 5, repeating: interval, leeway: .seconds(60))
            source.setEventHandler { run() }
            source.resume()
            timer = source
        }
    }

    /// Keeps the meeting out of every run until `release`: it is being transcribed.
    static func hold(_ id: String) {
        lock.withLock { busy[id, default: 0] += 1 }
    }

    static func release(_ id: String) {
        lock.withLock {
            busy[id, default: 1] -= 1
            if busy[id] == 0 { busy[id] = nil }
        }
    }

    static func isHeld(_ id: String) -> Bool {
        lock.withLock { busy[id] != nil }
    }

    @discardableResult
    static func run(now: Date = Date()) -> Report {
        run(now: now, in: Workspace.root, policy: Policy(), drive: { id, names in
            Sync.shared.deleteCopies(meetingID: id, names: names)
        })
    }

    /// One pass over the meeting folders in `root`. `drive` is told which synced copies to delete too.
    /// Blocking (compressing an hour of audio takes a few seconds); call it off the main thread.
    @discardableResult
    static func run(now: Date, in root: URL, policy: Policy, drive: (String, [String]) -> Void = { _, _ in }) -> Report {
        passLock.lock()
        defer { passLock.unlock() }
        var report = Report()
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in folders {
            guard let meta = Workspace.readMeta(folder), !isHeld(meta.id) else { continue }
            let file = { (name: String) in folder.appendingPathComponent(name) }
            let exists = { (name: String) in fm.fileExists(atPath: file(name).path) }
            let age = now.timeIntervalSince(meta.endedAt ?? meta.startedAt)
            let expired = { (days: Int) in days > 0 && age > TimeInterval(days) * 86_400 }
            var change: (inout MeetingMeta) -> Void = { _ in }

            // screen.mov stays behind when it could not be combined into meeting.mp4.
            let videos = videoNames.filter(exists)
            if expired(policy.keepVideoDays), !videos.isEmpty {
                var removed = false
                for name in videos {
                    let bytes = size(file(name))
                    if (try? fm.removeItem(at: file(name))) != nil {
                        removed = true
                        report.bytesFreed += bytes
                    }
                }
                if removed {
                    report.videosDeleted += 1
                    change = { $0.videoDeletedAt = now }
                }
            }

            // A transcript can only be made again from the tracks, so they stay until there is one.
            let transcribed = exists("transcript.md")
            let tracks = AudioTracks.fileNames.filter(exists)
            if transcribed, expired(policy.keepAudioDays), !tracks.isEmpty {
                var removed = 0
                for name in tracks {
                    let bytes = size(file(name))
                    if (try? fm.removeItem(at: file(name))) != nil {
                        removed += 1
                        report.bytesFreed += bytes
                    }
                }
                if removed > 0 {
                    report.audioDeleted += 1
                    let previous = change
                    change = { previous(&$0); $0.audioDeletedAt = now }
                }
            } else if transcribed, policy.compressAudio, tracks.contains(where: { $0.hasSuffix(".wav") }) {
                report.bytesCompressed += AudioTracks.compress(in: folder)
            }

            var current = meta
            change(&current)
            if current.videoDeletedAt != meta.videoDeletedAt || current.audioDeletedAt != meta.audioDeletedAt,
               !stamp(meta.id, at: folder, in: root, change) {
                // The folder vanished (deleted): no date was recorded, so Drive is not acted on either.
                continue
            }

            // Also retries copies a previous run could not delete (offline, signed out, sync folder away).
            let uploaded = Set((meta.drive?.files ?? [:]).keys).union((meta.sync?.files ?? [:]).keys)
            if policy.deleteOnDrive, !uploaded.isEmpty {
                var names: [String] = []
                if current.videoDeletedAt != nil, !exists("meeting.mp4") { names.append("meeting.mp4") }
                if current.audioDeletedAt != nil { names += AudioTracks.fileNames.filter { !exists($0) } }
                names = names.filter(uploaded.contains)
                if !names.isEmpty { drive(meta.id, names) }
            }
        }
        if report.videosDeleted + report.audioDeleted > 0 || report.bytesCompressed > 0 {
            Workspace.notifyChanged()
        }
        return report
    }

    static let videoNames = ["meeting.mp4", "screen.mov"]

    /// Writes the deletion dates. A rename can move the folder mid-pass, so it is looked up again before giving up.
    private static func stamp(_ id: String, at folder: URL, in root: URL, _ change: (inout MeetingMeta) -> Void) -> Bool {
        if (try? Workspace.updateMeta(folder, change)) != nil { return true }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard let moved = folders.first(where: { $0 != folder && Workspace.readMeta($0)?.id == id }) else { return false }
        return (try? Workspace.updateMeta(moved, change)) != nil
    }

    /// Bytes used by the workspace and the number of meetings in it. Walks every file; call it off the main thread.
    static func usage() -> (bytes: Int64, meetings: Int) {
        usage(in: Workspace.root)
    }

    static func usage(in root: URL) -> (bytes: Int64, meetings: Int) {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let meetings = folders.filter { fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }.count
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        if let files = fm.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in files {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return (bytes, meetings)
    }

    private static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
