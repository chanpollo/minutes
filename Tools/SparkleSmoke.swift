// Test host for updating an isolated copy of the app; never point it at a live installation.
import AppKit
import Sparkle

final class Driver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)) }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { print("Found update", appcastItem.versionString); reply(.install) }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { print("NO UPDATE", error); exit(2) }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { print("FAILED", error); exit(3) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { print("Installing verified update"); reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { print("INSTALLED", relaunched); acknowledgement(); exit(0) }
    func dismissUpdateInstallation() {}
}
final class Delegate: NSObject, SPUUpdaterDelegate {
    let feed: String
    init(_ feed: String) { self.feed = feed }
    func feedURLString(for updater: SPUUpdater) -> String? { feed }
}
let app = NSApplication.shared
let driver = Driver()
let delegate = Delegate(CommandLine.arguments[2])
let host = Bundle(path: CommandLine.arguments[1])!
let updater = SPUUpdater(hostBundle: host, applicationBundle: Bundle.main, userDriver: driver, delegate: delegate)
try updater.start()
DispatchQueue.main.async { updater.checkForUpdates() }
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("TIMED OUT"); exit(4) }
app.run()
