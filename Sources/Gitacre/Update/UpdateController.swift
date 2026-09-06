import Foundation
import Sparkle

/// Owns the Sparkle updater and exposes it to SwiftUI.
///
/// Sparkle handles the parts worth not reimplementing: fetching the appcast, verifying the
/// EdDSA signature and the Developer ID signature, staging the new bundle, and relaunching.
/// Everything the user sees is gitacre's own.
@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var state: UpdateState = .idle

    /// False when the app is not running from a bundle configured for updates, which is the
    /// case for `swift run` and for any build without a feed URL and public key.
    @Published private(set) var isAvailable = false

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard let updater, automaticallyChecksForUpdates != oldValue else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard let updater, automaticallyDownloadsUpdates != oldValue else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    private var updater: SPUUpdater?
    private var driver: UpdateDriver?

    init() {
        automaticallyChecksForUpdates = true
        automaticallyDownloadsUpdates = false

        let driver = UpdateDriver { [weak self] state in
            self?.state = state
        }
        self.driver = driver

        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )

        do {
            try updater.start()
            self.updater = updater
            isAvailable = true
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        } catch {
            // Running unbundled, or without SUFeedURL/SUPublicEDKey. The rest of the app
            // must keep working, so updates simply stay unavailable.
            isAvailable = false
        }
    }

    /// The version this build reports, preferring the full release label so a pre-release
    /// does not present itself as the final version of the same number.
    var currentVersion: String {
        let bundle = Bundle.main
        if let label = bundle.object(forInfoDictionaryKey: "GitacreReleaseLabel") as? String,
           !label.isEmpty {
            return label
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    var lastCheckDate: Date? {
        updater?.lastUpdateCheckDate
    }

    /// A check the user asked for: reports being up to date rather than staying silent.
    func checkForUpdates() {
        guard let updater, !state.isBusy else { return }
        updater.checkForUpdates()
    }

    func install() {
        driver?.install()
    }

    func dismiss() {
        driver?.dismiss()
    }

    func skipCurrentVersion() {
        driver?.skip()
    }
}
