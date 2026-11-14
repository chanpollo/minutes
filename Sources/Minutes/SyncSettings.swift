import AppKit
import SwiftUI

/// Settings › Sync: which way meetings are synced and that way's state; each setter writes through at once.
final class SyncModel: ObservableObject {
    enum ClientSheet: String, Identifiable {
        /// Connect… without a client: Continue saves it and signs in.
        case connect
        case edit
        var id: String { rawValue }
    }

    @Published var mode = Settings.syncMode {
        didSet {
            guard mode != oldValue else { return }
            Sync.shared.setMode(mode)
            refresh()
        }
    }
    @Published private(set) var places: [SyncPlace] = []
    @Published private(set) var folder = Settings.syncFolder
    @Published private(set) var status = FolderSync.shared.status
    @Published private(set) var example: (group: String?, meeting: String)?

    @Published private(set) var driveConnected = false
    @Published private(set) var connectingDrive = false
    @Published private(set) var driveStatus = DriveSync.shared.status
    @Published private(set) var clientID = DriveSync.clientID
    @Published var clientSheet: ClientSheet?

    @Published var uploadText = Settings.driveUploadText { didSet { changed { Settings.driveUploadText = uploadText } } }
    @Published var uploadMedia = Settings.driveUploadMedia { didSet { changed { Settings.driveUploadMedia = uploadMedia } } }
    @Published var perGroup = Settings.syncFolderPerGroup { didSet { changed { Settings.syncFolderPerGroup = perGroup } } }
    @Published var deleteThere = Settings.deleteOnDrive { didSet { Settings.deleteOnDrive = deleteThere } }

    private var observers: [NSObjectProtocol] = []
    private var exampleGeneration = 0

    init() {
        for name in [Notification.Name.driveStatusChanged, .syncStatusChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshState()
            })
        }
    }

    private func changed(_ write: () -> Void) {
        write()
        Sync.shared.enqueuePending()
    }

    /// The folder chosen, as one of the detected places or a hand-picked folder.
    var place: SyncPlace? {
        folder.map { SyncPlaces.place(at: $0, in: places) }
    }

    /// Detected places, plus the hand-picked folder when that is the one in use.
    var listed: [SyncPlace] {
        guard let place, place.kind == .other else { return places }
        return places + [place]
    }

    var folderMissing: Bool {
        if case .missing = status { return true }
        return false
    }

    func refresh() {
        places = SyncPlaces.detect()
        mode = Settings.syncMode
        refreshState()
        refreshExample()
        // Back after being away, or gone since the last pass: a pass finds out and copies what waits.
        if mode == .folder, let folder, FolderSync.isFolder(URL(fileURLWithPath: folder)) == folderMissing {
            FolderSync.shared.enqueuePending()
        }
    }

    func refreshState() {
        folder = Settings.syncFolder
        status = FolderSync.shared.status
        driveConnected = DriveSync.shared.isConnected
        driveStatus = DriveSync.shared.status
        clientID = DriveSync.clientID
    }

    /// The newest meeting, in a group when one is, for the layout line under "A folder for each group".
    private func refreshExample() {
        exampleGeneration += 1
        let generation = exampleGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let meetings = Workspace.meetings()
            let groups = Workspace.groups()
            let grouped = meetings.lazy.compactMap { item in
                groups.first { $0.id == item.meta.groupID }.map { (Optional($0.name), item.folder.lastPathComponent) }
            }.first
            let found = grouped ?? meetings.first.map { (nil, $0.folder.lastPathComponent) }
            DispatchQueue.main.async {
                guard let self, generation == self.exampleGeneration else { return }
                self.example = found.map { (group: $0.0, meeting: $0.1) }
            }
        }
    }

    var layout: String {
        let meeting = example?.meeting ?? "<meeting>"
        guard perGroup else { return "\(FolderSync.folderName) / \(meeting)" }
        return "\(FolderSync.folderName) / \(example?.group ?? "<group>") / \(meeting)"
    }

    // MARK: Folder

    func choose(_ place: SyncPlace) {
        Sync.shared.setFolder(place.path)
        refreshState()
    }

    func chooseOther(for window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Copies go into a Minutes folder inside the folder you choose."
        panel.directoryURL = folder.map { URL(fileURLWithPath: $0) } ?? SyncPlaces.home
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.choose(SyncPlaces.place(at: url.path, in: self?.places ?? []))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    func showInFinder() {
        guard let folder else { return }
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        let copies = FolderSync.destination(base)
        if FileManager.default.fileExists(atPath: copies.path) {
            NSWorkspace.shared.activateFileViewerSelecting([copies])
        } else if FolderSync.isFolder(base) {
            NSWorkspace.shared.open(base)
        }
    }

    func syncNow() {
        Sync.shared.enqueuePending()
    }

    // MARK: Google Drive

    func connectDrive() {
        guard !connectingDrive else { return }
        guard DriveSync.clientID != nil, DriveSync.clientSecret != nil else {
            clientSheet = .connect
            return
        }
        connectingDrive = true
        DriveSync.shared.connect { [weak self] error in
            self?.connectingDrive = false
            if let error {
                let alert = NSAlert(error: error)
                alert.messageText = "Could not connect Google Drive"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            } else {
                DriveSync.shared.enqueuePending()
            }
            self?.refreshState()
        }
    }

    func disconnectDrive() {
        DriveSync.shared.disconnect()
        refreshState()
    }

    func uploadNow() {
        DriveSync.shared.enqueuePending()
    }

    func editGoogleClient() {
        clientSheet = .edit
    }

    func saveClient(id: String, secret: String) {
        let sheet = clientSheet
        clientSheet = nil
        DriveSync.clientID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        DriveSync.clientSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        clientID = DriveSync.clientID
        if sheet == .connect { connectDrive() }
    }
}

/// The OAuth client of a Desktop app from Google Cloud Console, asked for before the first Connect… or with Edit….
struct GoogleClientSheet: View {
    let sheet: SyncModel.ClientSheet
    let save: (String, String) -> Void
    let cancel: () -> Void

    @State private var clientID = DriveSync.clientID ?? ""
    @State private var secret = DriveSync.clientSecret ?? ""
    @FocusState private var focused: Bool

    static let help = URL(string: "https://console.cloud.google.com/apis/credentials")!

    private var canSave: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty && !secret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Google OAuth client").font(.system(size: 13, weight: .bold))
                Text("From a Desktop app OAuth client in Google Cloud Console.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            field("Client ID") {
                TextField("Client ID", text: $clientID, prompt: Text("1234567890-abc.apps.googleusercontent.com"))
                    .focused($focused)
            }
            field("Client secret") {
                SecureField("Client secret", text: $secret, prompt: Text(""))
            }
            HStack(spacing: 8) {
                HelpLink(destination: Self.help)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(sheet == .connect ? "Continue" : "Save") { save(clientID, secret) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
    }
}
