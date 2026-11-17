import AppKit
import Sparkle

final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    var isBusy: () -> Bool = { true }
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: Timer?

    func start() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard !isBusy() else {
            let alert = NSAlert()
            alert.messageText = "Finish the current meeting task first"
            alert.informativeText = "Check for updates after recording and processing have finished."
            alert.runModal()
            return
        }
        start()
        controller?.checkForUpdates(sender)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pendingInstall?.invalidate()
        pendingInstall = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, !self.isBusy() else { return }
            timer.invalidate()
            self.pendingInstall = nil
            installHandler()
        }
        return true
    }
}
