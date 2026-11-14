import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct DriveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension Notification.Name {
    /// Posted on the main queue when `DriveSync.shared.status` or the connection changes.
    static let driveStatusChanged = Notification.Name("MinutesDriveStatusChanged")
}

/// Uploads meeting folders to My Drive/Minutes/<group name>/<folder name> (Minutes/<folder name> outside a group) with
/// the drive.file scope, one meeting at a time. Runs only while Settings sync to Google Drive signed in from Minutes.
final class DriveSync {
    static let shared = DriveSync()

    private init() {
        // Group moves and renames are local edits that only post meetingsChanged.
        NotificationCenter.default.addObserver(forName: .meetingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleGroupSync()
        }
    }

    static var clientID: String? {
        get { setting("googleClientID") }
        set { UserDefaults.standard.set(newValue, forKey: "googleClientID") }
    }

    static var clientSecret: String? {
        get { setting("googleClientSecret") }
        set { UserDefaults.standard.set(newValue, forKey: "googleClientSecret") }
    }

    static let chunkSize = 8 * 1024 * 1024 // resumable chunks must be multiples of 256 KiB
    static let signInTimeout: TimeInterval = 300
    private static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let filesURL = "https://www.googleapis.com/drive/v3/files"
    private static let uploadURL = "https://www.googleapis.com/upload/drive/v3/files"
    private static let rootFolderKey = "driveRootFolderID"
    // [group id: [Drive folder id, name it was given]]
    private static let groupFoldersKey = "driveGroupFolders"
    private static let folderType = "application/vnd.google-apps.folder"
    private static let attempts = 5

    private(set) var status: String?

    private let keychain = Keychain(service: "com.enta1234.minutes.google")
    private let worker = DispatchQueue(label: "minutes.drive", qos: .utility)
    private let http = URLSession(configuration: .ephemeral)
    private let lock = NSLock()
    private var refreshToken: String?
    private var tokenLoaded = false
    private var access: (token: String, expires: Date)?
    private var pending: [String] = []
    private var failed: [String] = []
    private var failure: String?
    private var running = false
    private var signIn: Loopback?
    private var groupSync: DispatchWorkItem?

    private struct Cancelled: Error {}
    private struct SessionExpired: Error {}

    private struct OAuthError: LocalizedError {
        let code: String
        let context: String
        var errorDescription: String? { "\(context): \(code)" }
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        if !tokenLoaded {
            refreshToken = keychain.read()
            tokenLoaded = true
        }
        return refreshToken != nil
    }

    // MARK: Sign-in

    func connect(completion: @escaping (Error?) -> Void) {
        let finish: (Error?) -> Void = { error in DispatchQueue.main.async { completion(error) } }
        guard let clientID = Self.clientID, let secret = Self.clientSecret else {
            return finish(DriveError(message: "Add the Google OAuth client ID and secret (Desktop app client) before connecting Drive"))
        }
        let verifier = PKCE.verifier()
        let loopback = Loopback(state: PKCE.verifier())
        lock.lock()
        signIn?.cancel()
        signIn = loopback
        lock.unlock()

        loopback.start(timeout: Self.signInTimeout, ready: { port in
            var consent = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            consent.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Self.scope),
                URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: loopback.state),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
            DispatchQueue.main.async { NSWorkspace.shared.open(consent.url!) }
        }, completion: { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            if self.signIn === loopback { self.signIn = nil }
            self.lock.unlock()
            switch result {
            case .failure(let error):
                finish(error)
            case .success(let code):
                let redirect = "http://127.0.0.1:\(loopback.port)"
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try self.exchange(code: code, verifier: verifier, redirect: redirect, clientID: clientID, secret: secret)
                        self.notify()
                        finish(nil)
                        self.enqueuePending()
                    } catch {
                        finish(error)
                    }
                }
            }
        })
    }

    func disconnect() {
        lock.lock()
        let token = tokenLoaded ? refreshToken : keychain.read()
        refreshToken = nil
        tokenLoaded = true
        access = nil
        pending.removeAll()
        failed.removeAll()
        failure = nil
        signIn?.cancel()
        signIn = nil
        lock.unlock()
        keychain.delete()
        if let token {
            var revoke = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            revoke.httpMethod = "POST"
            revoke.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            revoke.httpBody = Self.form([("token", token)])
            http.dataTask(with: revoke).resume()
        }
        setStatus(nil)
        notify()
    }

    private func exchange(code: String, verifier: String, redirect: String, clientID: String, secret: String) throws {
        let json = try tokenRequest([
            ("code", code), ("client_id", clientID), ("client_secret", secret), ("redirect_uri", redirect),
            ("grant_type", "authorization_code"), ("code_verifier", verifier),
        ], failure: "Google sign-in failed")
        guard let refresh = json["refresh_token"] as? String, let token = json["access_token"] as? String else {
            throw DriveError(message: "Google sign-in did not return offline access; try Connect again")
        }
        try keychain.save(refresh)
        lock.lock()
        refreshToken = refresh
        tokenLoaded = true
        access = (token, Self.expiry(json))
        lock.unlock()
    }

    private func accessToken(refresh force: Bool = false) throws -> String {
        lock.lock()
        let cached = access
        lock.unlock()
        if !force, let cached, cached.expires > Date() { return cached.token }
        guard isConnected else { throw Cancelled() }
        lock.lock()
        let stored = refreshToken
        lock.unlock()
        guard let refresh = stored else { throw Cancelled() }
        guard let clientID = Self.clientID, let secret = Self.clientSecret else {
            throw DriveError(message: "The Google OAuth client ID or secret is missing")
        }
        let json: [String: Any]
        do {
            json = try tokenRequest([
                ("refresh_token", refresh), ("client_id", clientID), ("client_secret", secret), ("grant_type", "refresh_token"),
            ], failure: "Google token refresh failed")
        } catch let error as OAuthError where error.code == "invalid_grant" {
            dropToken()
            throw DriveError(message: "Google Drive access expired or was revoked; connect Drive again")
        }
        guard let token = json["access_token"] as? String else { throw DriveError(message: "Google token refresh returned no token") }
        lock.lock()
        access = (token, Self.expiry(json))
        lock.unlock()
        return token
    }

    private func dropToken() {
        lock.lock()
        refreshToken = nil
        tokenLoaded = true
        access = nil
        pending.removeAll()
        lock.unlock()
        keychain.delete()
        notify()
    }

    private func tokenRequest(_ fields: [(String, String)], failure: String) throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let (data, response) = try retrying { try perform(request) }
        let json = Self.json(data)
        guard response.statusCode == 200 else {
            throw OAuthError(code: json["error"] as? String ?? "HTTP \(response.statusCode)", context: failure)
        }
        return json
    }

    // A minute early, so a token never expires between the check and the request.
    private static func expiry(_ json: [String: Any]) -> Date {
        Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int) ?? 3600) - 60)
    }

    // MARK: Queue

    private var active: Bool { Settings.syncMode == .googleDrive && isConnected }

    func enqueue(meetingID: String) {
        guard active else { return }
        lock.lock()
        // Meetings that gave up earlier go again with the next request.
        for id in failed + [meetingID] where !pending.contains(id) { pending.append(id) }
        failed.removeAll()
        let start = !running
        running = true
        lock.unlock()
        if start { worker.async { self.drain() } }
    }

    private func requeue(_ meetingID: String) {
        lock.lock()
        if !pending.contains(meetingID) { pending.append(meetingID) }
        lock.unlock()
    }

    func enqueuePending() {
        guard active else { return }
        DispatchQueue.global(qos: .utility).async {
            // A meeting being transcribed goes up when it is done; its tracks may still turn into FLAC.
            for meeting in Workspace.meetings()
            where !Housekeeping.isHeld(meeting.meta.id) && Self.needsUpload(meeting.folder, meeting.meta) {
                self.enqueue(meetingID: meeting.meta.id)
            }
        }
    }

    /// Another sync was chosen: queued meetings are dropped, the one uploading finishes.
    func stop() {
        lock.lock()
        pending.removeAll()
        failed.removeAll()
        failure = nil
        lock.unlock()
        setStatus(nil)
    }

    private func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty, Settings.syncMode == .googleDrive else {
            pending.removeAll()
            running = false
            return nil
        }
        return pending.removeFirst()
    }

    private func drain() {
        while let id = next() {
            do {
                try upload(meetingID: id)
                lock.lock()
                failed.removeAll { $0 == id }
                lock.unlock()
            } catch is Cancelled {
            } catch {
                let text = "Drive upload failed: \(error.localizedDescription)"
                lock.lock()
                if !failed.contains(id) { failed.append(id) }
                failure = text
                lock.unlock()
                setStatus(text)
            }
        }
        lock.lock()
        let left = failed.isEmpty ? nil : failure
        lock.unlock()
        setStatus(left)
    }

    private func setStatus(_ text: String?) {
        DispatchQueue.main.async {
            guard self.status != text else { return }
            self.status = text
            NotificationCenter.default.post(name: .driveStatusChanged, object: self)
        }
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .driveStatusChanged, object: self) }
    }

    // MARK: Meeting upload

    struct LocalFile {
        let name: String
        let url: URL
        let size: Int
        let modified: Date
    }

    static func needsUpload(_ folder: URL, _ meta: MeetingMeta) -> Bool {
        // A confidential meeting stays on this Mac; a copy made before it was marked has to go.
        if meta.confidential == true { return meta.drive?.folderID != nil }
        let placed = meta.drive?.folderID != nil
        let renamed = placed && meta.drive?.folderName != folder.lastPathComponent
        let moved = placed && meta.drive?.groupID != liveGroup(meta.groupID)
        return renamed || moved || !filesToUpload(in: folder, meta: meta).isEmpty
    }

    /// The files Settings send, as for a synced folder; pictures go to frames and attachments sub-folders.
    static func uploadNames(in folder: URL, meta: MeetingMeta) -> [String] {
        Sync.fileNames(in: folder, meta: meta)
    }

    /// Files that are new or differ in size or modification time from what meta.drive records.
    static func filesToUpload(in folder: URL, meta: MeetingMeta) -> [LocalFile] {
        uploadNames(in: folder, meta: meta).compactMap { name in
            let url = folder.appendingPathComponent(name)
            // meta.json stores whole seconds, so compare at that precision or every file looks changed.
            guard let (size, modified) = Sync.fileStamp(url) else { return nil }
            if let record = meta.drive?.files[name], record.size == size, wholeSeconds(record.modified) == modified { return nil }
            return LocalFile(name: name, url: url, size: size, modified: modified)
        }
    }

    /// The group id when that group still exists and Settings keep a folder per group.
    private static func liveGroup(_ id: String?) -> String? {
        Sync.liveGroup(id)?.id
    }

    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private func upload(meetingID: String) throws {
        guard Settings.syncMode == .googleDrive, let folder = locate(meetingID), let meta = Workspace.readMeta(folder), Self.needsUpload(folder, meta) else { return }
        // Renamed or deleted while uploading: pick it up again under its new name, or drop it.
        let moved = { self.locate(meetingID).map { $0.standardizedFileURL != folder.standardizedFileURL } }
        do {
            try upload(folder, meta: meta)
        } catch let error where !(error is Cancelled) {
            guard let moved = moved() else { return }
            guard !moved else { return requeue(meetingID) }
            throw error
        }
        if moved() == true { requeue(meetingID) }
    }

    private func upload(_ folder: URL, meta: MeetingMeta) throws {
        if meta.confidential == true { return try withdraw(meta) }
        setStatus("Uploading \(meta.title) · 0%")
        var drive = try meetingFolder(folder, meta: meta)
        guard let folderID = drive.folderID else { return }
        var current = meta
        current.drive = drive
        let files = Self.filesToUpload(in: folder, meta: current)
        let total = max(files.reduce(0) { $0 + $1.size }, 1)
        var done = 0
        var shown = 0
        for file in files {
            let parent = !file.name.contains("/") ? folderID
                : NotesAttachments.isAttachment(file.name) ? try attachmentsFolder(&drive, in: folderID, meetingID: meta.id)
                : try framesFolder(&drive, in: folderID, meetingID: meta.id)
            let id = try upload(file, replacing: drive.files[file.name]?.id, parent: parent) { sent in
                let percent = min((done + sent) * 100 / total, 100)
                guard percent != shown else { return }
                shown = percent
                self.setStatus("Uploading \(meta.title) · \(percent)%")
            }
            done += file.size
            try record(meta.id) { meta in
                var state = meta.drive ?? drive
                state.files[file.name] = DriveFile(id: id, size: file.size, modified: file.modified)
                meta.drive = state
            }
        }
        // A track compressed to FLAC after its WAV went up: the WAV copy is now a duplicate.
        let uploaded = Set(files.map(\.name))
        let stale = AudioTracks.names.filter { uploaded.contains("\($0).flac") }.map { "\($0).wav" }
            .filter { drive.files[$0] != nil && !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        if !stale.isEmpty { try trash(stale, of: meta.id) }
    }

    /// frames/ inside the meeting's Drive folder, made the first time a picture goes up.
    private func framesFolder(_ drive: inout DriveState, in parent: String, meetingID: String) throws -> String {
        if let id = drive.framesFolderID, try isLive(id) { return id }
        let id = try createFolder("frames", parent: parent)
        drive.framesFolderID = id
        try record(meetingID) { $0.drive?.framesFolderID = id }
        return id
    }

    /// attachments/ beside frames/, so notes.md's links work in the Drive copy too.
    private func attachmentsFolder(_ drive: inout DriveState, in parent: String, meetingID: String) throws -> String {
        if let id = drive.attachmentsFolderID, try isLive(id) { return id }
        let id = try createFolder(NotesAttachments.folderName, parent: parent)
        drive.attachmentsFolderID = id
        try record(meetingID) { $0.drive?.attachmentsFolderID = id }
        return id
    }

    // MARK: Deleting copies

    /// Marked confidential after it went up: its Drive folder, files and name included, goes to the Drive trash.
    private func withdraw(_ meta: MeetingMeta) throws {
        guard let id = meta.drive?.folderID else { return }
        let (data, response) = try request("PATCH", "\(Self.filesURL)/\(id)?fields=id", json: ["trashed": true])
        if response.statusCode != 404 { try Self.check(response, data, "remove \(meta.title) from Drive") }
        try record(meta.id) { $0.drive = nil }
    }

    /// Marked confidential while another sync, or none, is chosen: the copy on Drive still goes.
    func withdrawConfidential(meetingID: String) {
        guard isConnected else { return }
        worker.async {
            guard let folder = self.locate(meetingID), let meta = Workspace.readMeta(folder),
                  meta.confidential == true, meta.drive?.folderID != nil else { return }
            do {
                try self.withdraw(meta)
            } catch is Cancelled {
            } catch {
                self.setStatus("Drive clean-up failed: \(error.localizedDescription)")
            }
        }
    }

    /// Moves these files of the meeting to the Drive trash and forgets them; runs after any upload in progress.
    func deleteCopies(meetingID: String, names: [String]) {
        guard isConnected, !names.isEmpty else { return }
        worker.async {
            do {
                try self.trash(names, of: meetingID)
            } catch is Cancelled {
            } catch {
                // Kept in meta.drive, so the next clean-up tries again.
                self.setStatus("Drive clean-up failed: \(error.localizedDescription)")
            }
        }
    }

    /// The meeting was deleted here: its Drive folder goes to the Drive trash.
    func trashMeeting(_ meta: MeetingMeta) {
        guard isConnected, let id = meta.drive?.folderID else { return }
        worker.async {
            do {
                let (data, response) = try self.request("PATCH", "\(Self.filesURL)/\(id)?fields=id", json: ["trashed": true])
                if response.statusCode != 404 { try Self.check(response, data, "remove \(meta.title) from Drive") }
            } catch is Cancelled {
            } catch {
                self.setStatus("Drive clean-up failed: \(error.localizedDescription)")
            }
        }
    }

    /// A meeting deleted here came back: its Drive folder comes out of the Drive trash. Queued after the trash.
    func untrashMeeting(_ meta: MeetingMeta) {
        guard isConnected, let id = meta.drive?.folderID else { return }
        worker.async {
            do {
                let (data, response) = try self.request("PATCH", "\(Self.filesURL)/\(id)?fields=id", json: ["trashed": false])
                if response.statusCode == 404 {
                    // Gone for good: the next sync sends the meeting again in full.
                    try self.record(meta.id) { $0.drive = nil }
                    Sync.shared.enqueue(meetingID: meta.id)
                } else {
                    try Self.check(response, data, "restore \(meta.title) on Drive")
                }
            } catch is Cancelled {
            } catch {
                self.setStatus("Drive restore failed: \(error.localizedDescription)")
            }
        }
    }

    private func trash(_ names: [String], of meetingID: String) throws {
        guard let folder = locate(meetingID), let meta = Workspace.readMeta(folder) else { return }
        for name in names {
            guard let file = meta.drive?.files[name] else { continue }
            let (data, response) = try request("PATCH", "\(Self.filesURL)/\(file.id)?fields=id", json: ["trashed": true])
            if response.statusCode != 404 { try Self.check(response, data, "delete \(name) on Drive") }
            try record(meetingID) { $0.drive?.files[name] = nil }
        }
    }

    // A rename during an upload must not lose the Drive id it produced.
    private func record(_ meetingID: String, _ change: (inout MeetingMeta) -> Void) throws {
        try Sync.record(meetingID, change)
    }

    private func locate(_ meetingID: String) -> URL? {
        Sync.locate(meetingID)
    }

    /// The meeting's Drive folder, created under its group's folder (or the root folder) when missing or trashed,
    /// renamed and moved to match the local folder and group.
    private func meetingFolder(_ folder: URL, meta: MeetingMeta) throws -> DriveState {
        let name = folder.lastPathComponent
        let group = Self.liveGroup(meta.groupID)
        if var drive = meta.drive, let id = drive.folderID, try isLive(id) {
            if drive.folderName != name {
                let (data, response) = try request("PATCH", "\(Self.filesURL)/\(id)?fields=id", json: ["name": name])
                try Self.check(response, data, "rename the Drive folder")
                drive.folderName = name
                try record(meta.id) { $0.drive?.folderName = name }
            }
            if drive.groupID != group {
                let parent = try groupFolder(group)
                let (found, response) = try request("GET", "\(Self.filesURL)/\(id)?fields=parents")
                try Self.check(response, found, "look up the Drive folder of \(name)")
                let old = (Self.json(found)["parents"] as? [String] ?? []).joined(separator: ",")
                var move = URLComponents(string: "\(Self.filesURL)/\(id)")!
                move.queryItems = [URLQueryItem(name: "addParents", value: parent), URLQueryItem(name: "removeParents", value: old),
                                   URLQueryItem(name: "fields", value: "id")]
                let (data, moved) = try request("PATCH", move.url!.absoluteString, json: [:])
                try Self.check(moved, data, "move the Drive folder \(name)")
                drive.groupID = group
                try record(meta.id) { $0.drive?.groupID = group }
            }
            return drive
        }
        let drive = DriveState(folderID: try createFolder(name, parent: try groupFolder(group)), folderName: name, groupID: group)
        try record(meta.id) { $0.drive = drive }
        return drive
    }

    private func rootFolder() throws -> String {
        if let id = UserDefaults.standard.string(forKey: Self.rootFolderKey), try isLive(id) { return id }
        let id = try createFolder("Minutes", parent: nil)
        UserDefaults.standard.set(id, forKey: Self.rootFolderKey)
        return id
    }

    /// Minutes/<group name>, made when missing and renamed with the group; the root folder for no group.
    private func groupFolder(_ groupID: String?) throws -> String {
        let root = try rootFolder()
        guard let groupID, let group = Workspace.groups().first(where: { $0.id == groupID }) else { return root }
        var known = Self.groupFolders()
        if let entry = known[groupID], try isLive(entry.id) {
            if entry.name != group.name {
                let (data, response) = try request("PATCH", "\(Self.filesURL)/\(entry.id)?fields=id", json: ["name": group.name])
                try Self.check(response, data, "rename the Drive folder \(entry.name)")
                known[groupID] = (entry.id, group.name)
                Self.saveGroupFolders(known)
            }
            return entry.id
        }
        let id = try createFolder(group.name, parent: root)
        known[groupID] = (id, group.name)
        Self.saveGroupFolders(known)
        return id
    }

    private static func groupFolders() -> [String: (id: String, name: String)] {
        let stored = UserDefaults.standard.dictionary(forKey: groupFoldersKey) as? [String: [String]] ?? [:]
        return stored.compactMapValues { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    private static func saveGroupFolders(_ folders: [String: (id: String, name: String)]) {
        UserDefaults.standard.set(folders.mapValues { [$0.id, $0.name] }, forKey: groupFoldersKey)
    }

    // Debounced: a burst of local changes makes one pass.
    private func scheduleGroupSync() {
        groupSync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncGroups() }
        groupSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Renames group folders whose group was renamed, then uploads whatever changed, group moves included.
    private func syncGroups() {
        guard active else { return }
        let known = Self.groupFolders()
        let renamed = Workspace.groups().filter { group in known[group.id].map { $0.name != group.name } ?? false }
        if !renamed.isEmpty {
            worker.async {
                for group in renamed { _ = try? self.groupFolder(group.id) }
            }
        }
        enqueuePending()
    }

    /// False when the file or folder is gone or in the trash.
    private func isLive(_ id: String) throws -> Bool {
        let (data, response) = try request("GET", "\(Self.filesURL)/\(id)?fields=id,trashed")
        if response.statusCode == 404 { return false }
        try Self.check(response, data, "look up a Drive item")
        return Self.json(data)["trashed"] as? Bool != true
    }

    private func createFolder(_ name: String, parent: String?) throws -> String {
        var metadata: [String: Any] = ["name": name, "mimeType": Self.folderType]
        if let parent { metadata["parents"] = [parent] }
        var failures = 0
        while true {
            // A lost response may hide a folder Drive already made, so look for it before posting again.
            if failures > 0, let id = try findFolder(name, parent: parent) { return id }
            do {
                let (data, response) = try request("POST", "\(Self.filesURL)?fields=id", json: metadata, retry: false)
                if !(Self.isRetryable(response.statusCode) && failures + 1 < Self.attempts) {
                    try Self.check(response, data, "create the Drive folder \(name)")
                    guard let id = Self.json(data)["id"] as? String else { throw DriveError(message: "Drive returned no folder id") }
                    return id
                }
            } catch let error where Self.isTransient(error) && failures + 1 < Self.attempts {}
            failures += 1
            Thread.sleep(forTimeInterval: Self.backoff(failures))
        }
    }

    private func findFolder(_ name: String, parent: String?) throws -> String? {
        func quoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        }
        let query = "name = \(quoted(name)) and mimeType = \(quoted(Self.folderType)) and \(quoted(parent ?? "root")) in parents and trashed = false"
        var url = URLComponents(string: Self.filesURL)!
        url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "fields", value: "files(id)"),
                          URLQueryItem(name: "orderBy", value: "createdTime"), URLQueryItem(name: "pageSize", value: "1")]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let (data, response) = try request("GET", url.url!.absoluteString)
        try Self.check(response, data, "look for the Drive folder \(name)")
        return ((Self.json(data)["files"] as? [[String: Any]])?.first)?["id"] as? String
    }

    // MARK: Resumable upload

    private func upload(_ file: LocalFile, replacing existing: String?, parent: String, progress: (Int) -> Void) throws -> String {
        // New content written into a trashed copy would never show in the folder; upload a fresh file instead.
        var target = try existing.flatMap { try isLive($0) ? $0 : nil }
        for _ in 0..<3 {
            guard let session = try startSession(file, replacing: target, parent: parent) else {
                target = nil // deleted on Drive; upload it as a new file
                continue
            }
            do {
                return try send(file, to: session, progress: progress)
            } catch is SessionExpired {
                continue
            }
        }
        throw DriveError(message: "Drive kept rejecting the upload of \(file.name)")
    }

    private func startSession(_ file: LocalFile, replacing existing: String?, parent: String) throws -> URL? {
        var metadata: [String: Any] = ["name": (file.name as NSString).lastPathComponent]
        let url: String
        if let existing {
            url = "\(Self.uploadURL)/\(existing)?uploadType=resumable&fields=id"
        } else {
            url = "\(Self.uploadURL)?uploadType=resumable&fields=id"
            metadata["parents"] = [parent]
        }
        let (data, response) = try request(existing == nil ? "POST" : "PATCH", url, json: metadata, headers: [
            "X-Upload-Content-Type": Self.mimeType(file.name),
            "X-Upload-Content-Length": String(file.size),
        ])
        if existing != nil, response.statusCode == 404 { return nil }
        try Self.check(response, data, "start uploading \(file.name)")
        guard let location = response.value(forHTTPHeaderField: "Location"), let session = URL(string: location) else {
            throw DriveError(message: "Drive returned no upload session for \(file.name)")
        }
        return session
    }

    private func send(_ file: LocalFile, to session: URL, progress: (Int) -> Void) throws -> String {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var offset = 0
        var failures = 0
        var askStatus = false
        while true {
            var request = URLRequest(url: session)
            request.httpMethod = "PUT"
            if askStatus {
                request.setValue(Self.statusRange(total: file.size), forHTTPHeaderField: "Content-Range")
                request.httpBody = Data()
            } else {
                let length = min(Self.chunkSize, file.size - offset)
                try handle.seek(toOffset: UInt64(offset))
                let chunk = try handle.read(upToCount: length) ?? Data()
                guard chunk.count == length else { throw DriveError(message: "\(file.name) changed while uploading") }
                request.setValue(Self.contentRange(offset: offset, length: length, total: file.size), forHTTPHeaderField: "Content-Range")
                request.httpBody = chunk
            }

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try authorized(request)
            } catch let error where Self.isTransient(error) {
                failures += 1
                guard failures < Self.attempts else { throw error }
                Thread.sleep(forTimeInterval: Self.backoff(failures))
                askStatus = true
                continue
            }

            switch response.statusCode {
            case 200, 201:
                progress(file.size)
                guard let id = Self.json(data)["id"] as? String else { throw DriveError(message: "Drive returned no id for \(file.name)") }
                return id
            case 308:
                let committed = Self.committedBytes(range: response.value(forHTTPHeaderField: "Range"))
                if committed > offset {
                    failures = 0
                } else if !askStatus {
                    failures += 1
                    guard failures < Self.attempts else { throw DriveError(message: "Drive stopped accepting \(file.name)") }
                }
                offset = committed
                askStatus = false
                progress(offset)
            case 404, 410:
                throw SessionExpired()
            case 429, 500...599:
                failures += 1
                guard failures < Self.attempts else { throw Self.failure(response, data, "upload \(file.name)") }
                Thread.sleep(forTimeInterval: Self.backoff(failures))
                askStatus = true
            default:
                throw Self.failure(response, data, "upload \(file.name)")
            }
        }
    }

    static func contentRange(offset: Int, length: Int, total: Int) -> String {
        length == 0 ? "bytes */\(total)" : "bytes \(offset)-\(offset + length - 1)/\(total)"
    }

    static func statusRange(total: Int) -> String { "bytes */\(total)" }

    /// Bytes Drive has stored, from a 308's `Range: bytes=0-N`; none when the header is missing.
    static func committedBytes(range: String?) -> Int {
        guard let range, range.hasPrefix("bytes="), let last = range.split(separator: "-").last, let end = Int(last) else { return 0 }
        return end + 1
    }

    private static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension {
        case "mp4": return "video/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "md": return "text/markdown"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }

    // MARK: HTTP

    private func request(_ method: String, _ url: String, json: [String: Any]? = nil, headers: [String: String] = [:],
                         retry: Bool = true) throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        if let json {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return retry ? try retrying { try authorized(request) } : try authorized(request)
    }

    private func authorized(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(try accessToken())", forHTTPHeaderField: "Authorization")
        let result = try perform(request)
        guard result.1.statusCode == 401 else { return result }
        request.setValue("Bearer \(try accessToken(refresh: true))", forHTTPHeaderField: "Authorization")
        return try perform(request)
    }

    private func retrying(_ attempt: () throws -> (Data, HTTPURLResponse)) throws -> (Data, HTTPURLResponse) {
        var failures = 0
        while true {
            do {
                let result = try attempt()
                guard Self.isRetryable(result.1.statusCode), failures + 1 < Self.attempts else { return result }
            } catch let error where Self.isTransient(error) && failures + 1 < Self.attempts {}
            failures += 1
            Thread.sleep(forTimeInterval: Self.backoff(failures))
        }
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let done = DispatchSemaphore(value: 0)
        let result = Box<Result<(Data, HTTPURLResponse), Error>>(.failure(URLError(.badServerResponse)))
        http.dataTask(with: request) { data, response, error in
            if let error {
                result.value = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                result.value = .success((data ?? Data(), response))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.value.get()
    }

    private static func isTransient(_ error: Error) -> Bool { error is URLError }
    private static func isRetryable(_ status: Int) -> Bool { status == 429 || (500...599).contains(status) }
    private static func backoff(_ failures: Int) -> TimeInterval { pow(2, Double(failures - 1)) }

    private static func check(_ response: HTTPURLResponse, _ data: Data, _ action: String) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        throw failure(response, data, action)
    }

    private static func failure(_ response: HTTPURLResponse, _ data: Data, _ action: String) -> DriveError {
        let message = (json(data)["error"] as? [String: Any])?["message"] as? String
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        return DriveError(message: "Could not \(action): \(message) (HTTP \(response.statusCode))")
    }

    private static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { field, value in
            "\(field)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }

    private static func setting(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

// MARK: - OAuth pieces

extension DriveSync {
    /// RFC 7636 proof key; the verifier doubles as the random `state`.
    enum PKCE {
        static func verifier() -> String {
            base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        }

        static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    struct Keychain {
        let service: String
        private let account = "refresh-token"

        init(service: String) { self.service = service }

        private var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }

        func read() -> String? {
            var item: CFTypeRef?
            var search = query
            search[kSecReturnData as String] = true
            search[kSecMatchLimit as String] = kSecMatchLimitOne
            guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        func save(_ value: String) throws {
            delete()
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw DriveError(message: "Could not save the Google sign-in to the Keychain (\(status))") }
        }

        func delete() {
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Receives Google's redirect on http://127.0.0.1:<port>/ and hands back the authorization code once.
    final class Loopback {
        let state: String
        private(set) var port: UInt16 = 0
        private let queue = DispatchQueue(label: "minutes.drive.loopback")
        private var listener: NWListener?
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private var completion: ((Result<String, Error>) -> Void)?

        init(state: String) { self.state = state }

        func start(timeout: TimeInterval, ready: @escaping (UInt16) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
            queue.async { [self] in
                self.completion = completion
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [self] state in
                        switch state {
                        case .ready:
                            port = self.listener?.port?.rawValue ?? 0
                            ready(port)
                        case .failed(let error):
                            finish(.failure(error))
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [self] connection in
                        let key = ObjectIdentifier(connection)
                        connections[key] = connection
                        connection.stateUpdateHandler = { [weak self, weak connection] state in
                            switch state {
                            case .failed: connection?.cancel()
                            case .cancelled: self?.connections[key] = nil
                            default: break
                            }
                        }
                        connection.start(queue: queue)
                        receive(connection, Data())
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(DriveError(message: "Google sign-in timed out")))
                    }
                } catch {
                    finish(.failure(error))
                }
            }
        }

        func cancel() {
            queue.async { [self] in finish(.failure(DriveError(message: "Google sign-in was cancelled"))) }
        }

        // Browsers keep idle preconnects open; the listener's cancel does not close them.
        private func finish(_ result: Result<String, Error>, replying reply: NWConnection? = nil) {
            listener?.cancel()
            listener = nil
            for connection in connections.values where connection !== reply { connection.cancel() }
            guard let completion else { return }
            self.completion = nil
            completion(result)
        }

        private func receive(_ connection: NWConnection, _ received: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, isComplete, error in
                var buffer = received
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
                } else if isComplete || error != nil || buffer.count > 16_384 {
                    connection.cancel()
                } else {
                    receive(connection, buffer)
                }
            }
        }

        private func respond(_ connection: NWConnection, head: String) {
            let target = head.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let url = URLComponents(string: target)
            let query = Dictionary((url?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            var result: Result<String, Error>?
            let reply: (code: Int, text: String)
            if url?.path != "/" {
                reply = (404, "Not found")
            } else if query["state"] != state {
                // Not this sign-in (stale tab or another page); keep waiting for the real redirect.
                reply = (400, "This sign-in link is out of date. Use Connect in Minutes again.")
            } else if let code = query["code"], !code.isEmpty {
                reply = (200, "Minutes is connected. You can close this tab.")
                result = .success(code)
            } else {
                let reason = query["error"] ?? "no authorization code"
                reply = (400, "Minutes could not connect to Google Drive (\(reason)). You can close this tab.")
                result = .failure(DriveError(message: "Google sign-in failed: \(reason)"))
            }
            let body = Data((reply.text + "\n").utf8)
            let status = [200: "OK", 400: "Bad Request"][reply.code] ?? "Not Found"
            let headers = "HTTP/1.1 \(reply.code) \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            if let result { finish(result, replying: connection) }
        }
    }
}
