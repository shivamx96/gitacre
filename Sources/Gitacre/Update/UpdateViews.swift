import SwiftUI

/// The inline update surface, shown above the panel footer.
///
/// It only takes space when there is something to say, so the panel is unchanged for the
/// overwhelming majority of launches where the app is already current.
struct UpdateBanner: View {
    @EnvironmentObject private var updates: UpdateController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch updates.state {
            case .idle, .upToDate:
                EmptyView()
            case .checking:
                banner(symbol: "arrow.triangle.2.circlepath", title: "Checking for updates…") { EmptyView() }
            case let .available(release):
                banner(symbol: "arrow.down.circle", title: "\(release.title) is available") {
                    HStack(spacing: 8) {
                        if let notes = release.releaseNotesURL {
                            Link("Notes", destination: notes)
                                .font(.system(size: 10))
                                .foregroundStyle(GitacreTheme.secondaryInk(colorScheme))
                        }
                        bannerButton("Later", prominent: false, action: updates.dismiss)
                        bannerButton("Update", prominent: true, action: updates.install)
                    }
                }
            case .downloading, .extracting:
                banner(symbol: "arrow.down.circle", title: progressTitle) {
                    ProgressView(value: updates.state.fractionComplete ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 76)
                        .opacity(updates.state.fractionComplete == nil ? 0.4 : 1)
                }
            case let .readyToInstall(release):
                banner(symbol: "checkmark.circle", title: "\(release.title) is ready") {
                    HStack(spacing: 8) {
                        bannerButton("Later", prominent: false, action: updates.dismiss)
                        bannerButton("Relaunch", prominent: true, action: updates.install)
                    }
                }
            case .installing:
                banner(symbol: "gearshape", title: "Installing…") { EmptyView() }
            case let .failed(message):
                banner(symbol: "exclamationmark.triangle", title: message, role: .blocked) {
                    bannerButton("Dismiss", prominent: false, action: updates.dismiss)
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: updates.state)
    }

    private var progressTitle: String {
        if case .extracting = updates.state { return "Preparing update…" }
        return "Downloading update…"
    }

    @ViewBuilder
    private func banner<Trailing: View>(
        symbol: String,
        title: String,
        role: StatusRole = .drift,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(role.color(colorScheme))
            Text(title)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(role.color(colorScheme).opacity(0.07))
        .overlay(alignment: .top) {
            Rectangle().fill(GitacreTheme.hairline(colorScheme)).frame(height: 0.5)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func bannerButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? GitacreTheme.primaryInk(colorScheme) : GitacreTheme.secondaryInk(colorScheme))
    }
}

/// The updates group in Settings › General.
struct UpdateSettings: View {
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        SettingsGroup(title: "UPDATES") {
            SettingsRow(title: "Current version", detail: lastCheckDetail) {
                Text(updates.currentVersion)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            SettingsRow(title: "Check automatically", detail: "Signed with the release key and verified before install") {
                Toggle("", isOn: $updates.automaticallyChecksForUpdates)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!updates.isAvailable)
            }
            SettingsRow(title: "Download in the background", detail: "Install on the next relaunch") {
                Toggle("", isOn: $updates.automaticallyDownloadsUpdates)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!updates.isAvailable || !updates.automaticallyChecksForUpdates)
            }
            SettingsRow(title: "Check now", detail: updates.isAvailable ? nil : "Unavailable in this build") {
                Button("Check", action: updates.checkForUpdates)
                    .controlSize(.small)
                    .disabled(!updates.isAvailable || updates.state.isBusy)
            }
        }
    }

    private var lastCheckDetail: String? {
        guard updates.isAvailable else { return "Updates are not configured for this build" }
        if case .upToDate = updates.state { return "Up to date" }
        guard let date = updates.lastCheckDate else { return "Not checked yet" }
        return "Last checked \(compactRelativeDate(date)) ago"
    }
}
