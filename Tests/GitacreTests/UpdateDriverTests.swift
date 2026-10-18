import XCTest
@testable import Gitacre

final class UpdateDriverTests: XCTestCase {
    @MainActor
    func testNoUpdateResultSurvivesSynchronousAndDeferredCleanup() {
        var states: [UpdateState] = []
        let driver = UpdateDriver { states.append($0) }
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        driver.showUpdateNotFoundWithError(NSError(domain: "test", code: 0)) {
            driver.dismissUpdateInstallation()
        }
        XCTAssertEqual(states.last, .upToDate)
        driver.dismissUpdateInstallation()
        XCTAssertEqual(states.last, .upToDate)
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        XCTAssertEqual(states.last, .checking)
    }

    @MainActor
    func testErrorRemainsVisibleUntilExplicitDismissal() {
        var states: [UpdateState] = []
        let driver = UpdateDriver { states.append($0) }
        driver.showUpdaterError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])) {
            driver.dismissUpdateInstallation()
        }
        driver.dismissUpdateInstallation()
        XCTAssertEqual(states.last, .failed("Network unavailable"))
        driver.dismiss()
        XCTAssertEqual(states.last, .idle)
    }

    @MainActor
    func testCancelCheckInvokesCancellationAndReturnsToIdle() {
        var cancelled = false
        var state: UpdateState = .idle
        let driver = UpdateDriver { state = $0 }
        driver.showUserInitiatedUpdateCheck { cancelled = true }
        driver.dismiss()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(state, .idle)
    }
}
