import XCTest
import Sparkle
@testable import Minutes

final class AppUpdaterTests: XCTestCase {
    func testInstallationWaitsForActiveWorkAndResumesWhenIdle() {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let item = SUAppcastItem(dictionary: ["title": "Test", "sparkle:version": "22",
            "enclosure": ["url": "https://example.com/update.dmg", "sparkle:version": "22"]])!
        let gate = AppUpdater()
        var busy = true
        var installed = false
        gate.isBusy = { busy }
        let resumed = expectation(description: "Installation resumes after active work finishes")
        XCTAssertTrue(gate.updater(controller.updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {
            XCTAssertFalse(busy)
            installed = true
            resumed.fulfill()
        }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(installed, "Must not install while a meeting task is active")
            busy = false
        }
        wait(for: [resumed], timeout: 3)
        XCTAssertFalse(gate.updater(controller.updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: {
            XCTFail("An idle updater should proceed directly without retaining the callback")
        }))
    }
}
