import Foundation

/// Where an update currently is, from the panel's point of view.
///
/// Sparkle drives its own multi-window flow by default. gitacre lives in the menu bar with
/// no main window, so it drives the flow itself and renders progress inline instead.
enum UpdateState: Equatable {
    case idle
    case checking
    /// An update is available and waiting on the user.
    case available(UpdateRelease)
    case downloading(received: UInt64, expected: UInt64)
    case extracting(fraction: Double)
    /// Downloaded and staged; installing requires relaunching.
    case readyToInstall(UpdateRelease)
    case installing
    /// A check the user asked for came back empty.
    case upToDate
    case failed(String)

    var release: UpdateRelease? {
        switch self {
        case let .available(release), let .readyToInstall(release): release
        default: nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .extracting, .installing: true
        default: false
        }
    }

    /// Fraction complete, when it is known. Download size is absent often enough that the
    /// bar has to be able to fall back to indeterminate.
    var fractionComplete: Double? {
        switch self {
        case let .downloading(received, expected):
            expected > 0 ? min(1, Double(received) / Double(expected)) : nil
        case let .extracting(fraction):
            fraction
        default:
            nil
        }
    }
}

struct UpdateRelease: Equatable {
    /// What the release calls itself, for example "1.1.0" or "1.1.0-beta".
    let displayVersion: String
    /// The build number Sparkle actually compares.
    let buildVersion: String
    let releaseNotesURL: URL?
    let publishedAt: Date?

    var title: String {
        "Version \(displayVersion)"
    }
}
