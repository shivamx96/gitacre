import XCTest
@testable import Gitacre

final class UpdateStateTests: XCTestCase {
    private let release = UpdateRelease(
        displayVersion: "1.1.0-beta",
        buildVersion: "7",
        releaseNotesURL: URL(string: "https://example.com/notes"),
        publishedAt: nil
    )

    func testProgressIsIndeterminateUntilTheDownloadSizeIsKnown() {
        // Sparkle reports received bytes before it reports the expected length, so the bar
        // has to distinguish "no progress yet" from "0% of a known total".
        XCTAssertNil(UpdateState.downloading(received: 0, expected: 0).fractionComplete)
        XCTAssertNil(UpdateState.downloading(received: 512, expected: 0).fractionComplete)
        XCTAssertEqual(UpdateState.downloading(received: 512, expected: 1024).fractionComplete, 0.5)
    }

    func testProgressNeverExceedsOne() {
        // A resumed or over-reported download must not push the bar past full.
        XCTAssertEqual(UpdateState.downloading(received: 2048, expected: 1024).fractionComplete, 1)
    }

    func testExtractionReportsItsOwnProgress() {
        XCTAssertEqual(UpdateState.extracting(fraction: 0.25).fractionComplete, 0.25)
    }

    func testOnlyInFlightStatesAreBusy() {
        for state in [
            UpdateState.checking,
            .downloading(received: 0, expected: 1),
            .extracting(fraction: 0),
            .installing
        ] {
            XCTAssertTrue(state.isBusy, "\(state) should block a second check")
        }

        for state in [
            UpdateState.idle,
            .upToDate,
            .available(release),
            .readyToInstall(release),
            .failed("boom")
        ] {
            XCTAssertFalse(state.isBusy, "\(state) should not block a second check")
        }
    }

    func testTheReleaseIsReadableWhileItIsBeingOffered() {
        XCTAssertEqual(UpdateState.available(release).release, release)
        XCTAssertEqual(UpdateState.readyToInstall(release).release, release)
        XCTAssertNil(UpdateState.checking.release)
        XCTAssertNil(UpdateState.idle.release)
    }

    func testReleaseTitleUsesTheLabelRatherThanTheBuildNumber() {
        XCTAssertEqual(release.title, "Version 1.1.0-beta")
    }
}
