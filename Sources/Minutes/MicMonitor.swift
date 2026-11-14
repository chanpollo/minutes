import AppKit
import CoreAudio

struct MicUser: Hashable {
    let bundleID: String
    /// The regular app the process belongs to, or `bundleID` when none is found.
    let ownerBundleID: String
    let appName: String

    // Apple daemons (dictation, Siri) also open the mic; only these Apple ones are calls.
    private static let appleCallApps = ["com.apple.FaceTime", "com.apple.avconferenced", "com.apple.Safari", "com.apple.WebKit"]

    var isMeetingCandidate: Bool {
        guard bundleID.hasPrefix("com.apple.") else { return !bundleID.isEmpty }
        return Self.appleCallApps.contains { bundleID.hasPrefix($0) }
    }
}

/// Polls Core Audio for processes that currently have an input stream running.
final class MicMonitor {
    var onChange: (([MicUser]) -> Void)?
    /// Apps playing sound at the last poll, by the same names as the mic users.
    private(set) var outputApps: Set<String> = []
    private var timer: Timer?
    private let ownPID = getpid()

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        onChange?(currentUsers())
    }

    private func currentUsers() -> [MicUser] {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let regularIDs = regular.compactMap(\.bundleIdentifier)
        var users = Set<MicUser>()
        var output = Set<String>()
        for process in CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList) {
            let input = (try? CA.get(process, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) == 1
            let playing = (try? CA.get(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) == 1
            guard input || playing,
                  let pid = try? CA.get(process, kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid != ownPID
            else { continue }
            let bundleID = CA.string(process, kAudioProcessPropertyBundleID) ?? ""
            let owner = bundleID.isEmpty ? "" : MeetingApps.owner(of: bundleID, regularApps: regularIDs)
            if playing { output.insert(appName(pid: pid, owner: owner, regular: regular)) }
            guard input else { continue }
            users.insert(MicUser(
                bundleID: bundleID, ownerBundleID: owner,
                appName: appName(pid: pid, owner: owner, regular: regular)))
        }
        outputApps = output
        return Array(users)
    }

    // Browsers and Electron apps capture audio in helper processes (com.google.Chrome.helper);
    // name them after the app the user sees.
    private func appName(pid: pid_t, owner: String, regular: [NSRunningApplication]) -> String {
        if let name = regular.first(where: { $0.bundleIdentifier == owner })?.localizedName { return name }
        if let name = MeetingApps.known[owner] { return name }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? owner
    }
}
