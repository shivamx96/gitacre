import Foundation
import Sparkle

/// Translates Sparkle's update flow into `UpdateState`, and holds the replies Sparkle is
/// waiting on so the panel's buttons can answer them.
///
/// Sparkle's stock driver puts up its own windows. That suits an app with a main window;
/// gitacre is an `LSUIElement` menu bar app, so it renders the same flow inline.
@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
    private let onStateChange: (UpdateState) -> Void

    private var updateChoice: ((SPUUserUpdateChoice) -> Void)?
    private var installChoice: ((SPUUserUpdateChoice) -> Void)?
    private var cancelInFlightWork: (() -> Void)?
    private var acknowledgeDismissal: (() -> Void)?

    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0
    private var pendingRelease: UpdateRelease?

    init(onStateChange: @escaping (UpdateState) -> Void) {
        self.onStateChange = onStateChange
    }

    // MARK: - Actions the panel can take

    var canInstall: Bool { updateChoice != nil || installChoice != nil }

    /// Accepts the update Sparkle is offering, downloading it if it is not staged yet.
    func install() {
        if let installChoice {
            self.installChoice = nil
            installChoice(.install)
        } else if let updateChoice {
            self.updateChoice = nil
            updateChoice(.install)
        }
    }

    /// Declines the current offer and returns to idle.
    func dismiss() {
        cancelInFlightWork?()
        cancelInFlightWork = nil
        acknowledgeDismissal?()
        acknowledgeDismissal = nil

        let choice = updateChoice ?? installChoice
        updateChoice = nil
        installChoice = nil
        choice?(.dismiss)

        report(.idle)
    }

    /// Skips this version so Sparkle stops offering it.
    func skip() {
        guard let updateChoice else { return dismiss() }
        self.updateChoice = nil
        updateChoice(.skip)
        report(.idle)
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Automatic checks are a gitacre setting, so Sparkle never asks on its own. The
        // system profile is never sent: the app reports nothing about the machine.
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelInFlightWork = cancellation
        report(.checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let release = UpdateRelease(
            displayVersion: appcastItem.displayVersionString,
            buildVersion: appcastItem.versionString,
            releaseNotesURL: appcastItem.fullReleaseNotesURL ?? appcastItem.releaseNotesURL,
            publishedAt: appcastItem.date
        )
        pendingRelease = release

        // An update already downloaded on a previous launch arrives here ready to install.
        if state.stage == .installing {
            installChoice = reply
            report(.readyToInstall(release))
        } else {
            updateChoice = reply
            report(.available(release))
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        report(.upToDate)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        report(.failed(Self.message(for: error)))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelInFlightWork = cancellation
        expectedContentLength = 0
        receivedContentLength = 0
        report(.downloading(received: 0, expected: 0))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
        report(.downloading(received: receivedContentLength, expected: expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        report(.downloading(received: receivedContentLength, expected: expectedContentLength))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelInFlightWork = nil
        report(.extracting(fraction: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        report(.extracting(fraction: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installChoice = reply
        report(.readyToInstall(pendingRelease ?? Self.unknownRelease))
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        report(.installing)
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
        report(.idle)
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        cancelInFlightWork = nil
        updateChoice = nil
        installChoice = nil
        // A finished or abandoned installation returns to idle; a failure has already
        // reported itself through showUpdaterError.
        if case .failed = currentState { return }
        report(.idle)
    }

    // MARK: - Helpers

    private var currentState: UpdateState = .idle

    private func report(_ state: UpdateState) {
        currentState = state
        onStateChange(state)
    }

    private static let unknownRelease = UpdateRelease(
        displayVersion: "the latest version",
        buildVersion: "",
        releaseNotesURL: nil,
        publishedAt: nil
    )

    private static func message(for error: any Error) -> String {
        let error = error as NSError
        // Sparkle nests the useful reason; its own description is usually generic.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           !underlying.localizedDescription.isEmpty {
            return underlying.localizedDescription
        }
        return error.localizedDescription
    }
}
