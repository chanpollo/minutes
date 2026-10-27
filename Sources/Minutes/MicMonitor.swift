import AppKit
import CoreAudio

struct MicUser: Hashable {
    let bundleID: String
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
        let running = NSWorkspace.shared.runningApplications
        var users = Set<MicUser>()
        for process in CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList) {
            guard (try? CA.get(process, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) == 1,
                  let pid = try? CA.get(process, kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid != ownPID
            else { continue }
            let bundleID = CA.string(process, kAudioProcessPropertyBundleID) ?? ""
            users.insert(MicUser(bundleID: bundleID, appName: appName(pid: pid, bundleID: bundleID, running: running)))
        }
        return Array(users)
    }

    // Browsers and Electron apps capture audio in helper processes (com.google.Chrome.helper);
    // name them after the app the user sees.
    private func appName(pid: pid_t, bundleID: String, running: [NSRunningApplication]) -> String {
        if let owner = running.first(where: {
            $0.activationPolicy == .regular && ($0.bundleIdentifier.map { bundleID == $0 || bundleID.hasPrefix($0 + ".") } ?? false)
        }), let name = owner.localizedName {
            return name
        }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleID
    }
}
