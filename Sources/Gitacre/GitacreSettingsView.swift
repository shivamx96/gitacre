import AppKit
import GitacreCore
import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general = "General"
    case repositories = "Repositories"
    case github = "GitHub"
    case terminal = "Terminal"
    case advanced = "Advanced"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .repositories: "folder"
        case .github: "arrow.triangle.pull"
        case .terminal: "apple.terminal"
        case .advanced: "gearshape.2"
        }
    }
}

struct GitacreSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var destination = SettingsDestination.general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(GitacreTheme.hairline(colorScheme)).frame(width: 0.5)
            detail
        }
        .frame(width: 660, height: 472)
        .background(GitacreTheme.surface(colorScheme))
        .tint(GitacreTheme.accent(colorScheme))
        .preferredColorScheme(model.appearance.colorScheme)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text("gitacre")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)

            ForEach(SettingsDestination.allCases) { item in
                Button { destination = item } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 16)
                        Text(item.rawValue)
                            .font(.system(size: 11.5, weight: destination == item ? .semibold : .medium))
                        Spacer()
                    }
                    .foregroundStyle(destination == item ? GitacreTheme.primaryInk(colorScheme) : GitacreTheme.secondaryInk(colorScheme))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(destination == item ? GitacreTheme.selected(colorScheme) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
            Text(model.applicationVersion)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(width: 154)
        .background(GitacreTheme.chrome(colorScheme))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(destination.rawValue)
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 20)
                .frame(height: 48, alignment: .leading)

            ScrollView {
                Group {
                    switch destination {
                    case .general: GeneralSettings()
                    case .repositories: RepositorySettings()
                    case .github: GitHubSettings()
                    case .terminal: TerminalSettings()
                    case .advanced: AdvancedSettings()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            SettingsGroup(title: "APPEARANCE") {
                SettingsRow(title: "Theme") {
                    Picker("Theme", selection: $model.appearance) {
                        ForEach(GitacreAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                }
                SettingsRow(title: "Menu-bar icon") {
                    Picker("Menu-bar icon", selection: $model.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                }
                SettingsRow(title: "Dim when idle", detail: "Reduces emphasis when nothing needs attention") {
                    Toggle("", isOn: $model.dimIconWhenIdle).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }

            SettingsGroup(title: "BEHAVIOUR") {
                SettingsRow(title: "Launch at login", detail: "Registered with the macOS login-items service") {
                    Toggle("", isOn: Binding(
                        get: { model.isLaunchAtLoginEnabled },
                        set: model.setLaunchAtLogin
                    )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "Opens showing", detail: "Pending, if any; otherwise All") {
                    Text("Automatic").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                SettingsRow(title: "Refresh automatically", detail: "Every 60 seconds and whenever the panel opens") {
                    Toggle("", isOn: $model.refreshAutomatically).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "Global shortcut") {
                    Text("⌥⌘G")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }
}

private struct RepositorySettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            SettingsGroup(title: "MONITORED FOLDERS", subtitle: "Scanned every 60s · \(model.repositories.count) repositories found") {
                if model.roots.isEmpty {
                    SettingsRow(title: "No folders monitored", detail: "Add the folder where you keep repositories") { EmptyView() }
                } else {
                    ForEach(model.roots, id: \.self) { root in
                        SettingsRow(title: abbreviated(root), detail: rootDetail(root)) {
                            Button { model.removeRepositoryRoot(root) } label: {
                                Image(systemName: "minus").frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove folder")
                        }
                    }
                }
                SettingsRow(title: "Add another folder") {
                    Button { model.addRepositoryRoot() } label: {
                        Label("Add…", systemImage: "plus")
                    }.buttonStyle(QuietButtonStyle())
                }
            }

            SettingsGroup(title: "SCANNING") {
                SettingsRow(title: "Maximum search depth", detail: "Levels below each monitored folder") {
                    Stepper("\(model.maximumScanDepth)", value: $model.maximumScanDepth, in: 1...8)
                        .labelsHidden().frame(width: 72)
                }
                SettingsRow(title: "Include worktrees", detail: "Detected with git worktree list") {
                    Toggle("", isOn: $model.includeWorktrees).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "Ignore paths matching") {
                    TextField("node_modules, .build, vendor", text: $model.ignoredPathNames)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10.5)).frame(width: 210)
                }
                SettingsRow(title: "Apply scanning changes") {
                    Button("Rescan") { Task { await model.refreshRepositories() } }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    private func rootDetail(_ root: String) -> String {
        guard FileManager.default.fileExists(atPath: root) else { return "folder missing" }
        let count = model.repositories.filter { repository in
            repository.worktrees.contains { $0.path.hasPrefix(root + "/") || $0.path == root }
        }.count
        return "\(count) repo\(count == 1 ? "" : "s") · depth \(model.maximumScanDepth)"
    }
}

private struct GitHubSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            SettingsGroup(title: "ACCOUNT") {
                SettingsRow(title: accountTitle, detail: "gitacre reuses your active gh session") {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                }
                if let executable = model.githubSnapshot.authentication.executable {
                    SettingsRow(title: "Executable", detail: executable) {
                        Button("Locate…") { model.chooseGitHubCLI() }.buttonStyle(QuietButtonStyle())
                    }
                } else {
                    SettingsRow(title: "Executable", detail: "gh was not found in common locations") {
                        Button("Locate…") { model.chooseGitHubCLI() }.buttonStyle(QuietButtonStyle())
                    }
                }
                SettingsRow(title: "Authentication") {
                    Button("Re-authenticate") { model.copyAndOpenTerminal("gh auth login --hostname github.com") }
                        .buttonStyle(QuietButtonStyle())
                }
            }

            SettingsGroup(title: "PULL REQUESTS") {
                SettingsRow(title: "Review requests") {
                    Toggle("", isOn: $model.showReviewRequests).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "Opened by you") {
                    Toggle("", isOn: $model.showAuthoredPullRequests).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "Include drafts") {
                    Toggle("", isOn: $model.showDraftPullRequests).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "Limit to organisations", detail: "Comma-separated GitHub owners") {
                    TextField("acre-labs, ledger-io", text: $model.githubOrganizations)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10.5)).frame(width: 190)
                }
                SettingsRow(title: "Poll pull requests", detail: "Every 5 minutes; ⌘R refreshes now") {
                    Toggle("", isOn: $model.pollPullRequests).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsRow(title: "New review requests", detail: "Show a macOS notification") {
                    Toggle("", isOn: Binding(
                        get: { model.notifyReviewRequests },
                        set: model.requestReviewNotifications
                    )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private var accountTitle: String {
        switch model.githubSnapshot.authentication {
        case .cliMissing: "GitHub CLI not installed"
        case .signedOut: "Not authenticated"
        case let .signedIn(_, login): "Authenticated as \(login)"
        case .unavailable: "GitHub temporarily unavailable"
        }
    }

    private var statusColor: Color {
        switch model.githubSnapshot.authentication {
        case .signedIn: .green
        case .signedOut, .unavailable: .orange
        case .cliMissing: .secondary
        }
    }
}

private struct TerminalSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            SettingsGroup(title: "DEFAULT TERMINAL", subtitle: "\(model.terminalApplications.count) installed apps detected") {
                ForEach(model.terminalApplications) { application in
                    TerminalRow(application: application)
                }
                SettingsRow(title: "Choose another application", detail: "Hyper, Tabby, and other terminals are supported") {
                    Button("Choose…") { model.chooseTerminalApplication() }.buttonStyle(QuietButtonStyle())
                }
                SettingsRow(title: "Refresh installed applications") {
                    Button("Rescan") { model.refreshTerminalApplications() }.buttonStyle(QuietButtonStyle())
                }
            }
        }
    }
}

private struct TerminalRow: View {
    @EnvironmentObject private var model: AppModel
    let application: TerminalApplication

    var body: some View {
        SettingsRow(title: application.name, detail: application.abbreviatedPath) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                    .resizable().frame(width: 18, height: 18)
                Image(systemName: model.selectedTerminalApplication?.id == application.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selectedTerminalApplication?.id == application.id ? Color.accentColor : .secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectTerminalApplication(application.id) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectTerminalApplication(application.id) }
    }
}

private struct AdvancedSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            SettingsGroup(title: "GIT") {
                SettingsRow(title: "Executable", detail: "/usr/bin/git") { Text("System").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                SettingsRow(title: "Concurrent scans", detail: "Repositories are scanned off the main thread") { Text("Automatic").font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }

            SettingsGroup(title: "CACHE & DIAGNOSTICS") {
                SettingsRow(title: "GitHub cache", detail: cacheSize) {
                    Button("Clear") { model.clearRepositoryCache() }.buttonStyle(QuietButtonStyle())
                }
                SettingsRow(title: "Diagnostics", detail: "Copies configuration without credentials") {
                    Button("Copy report") { model.copyDiagnostics() }.buttonStyle(QuietButtonStyle())
                }
                SettingsRow(title: "Refresh all data") {
                    Button("Refresh") { Task { await model.refreshAll() } }.buttonStyle(QuietButtonStyle())
                }
            }

            Text("\(model.applicationVersion) · monitored folders are kept when caches are cleared")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cacheSize: String {
        guard let url = AppModel.githubCacheURL(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attributes[.size] as? NSNumber else { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 9.5, weight: .semibold)).tracking(0.65)
                Spacer()
                if let subtitle { Text(subtitle).font(.system(size: 9.5)).tracking(0) }
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)

            VStack(spacing: 0) { content }
                .background(GitacreTheme.chrome(colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(GitacreTheme.hairline(colorScheme), lineWidth: 0.5)
                }
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let trailing: Trailing
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 11)
        .frame(minHeight: detail == nil ? 36 : 43)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GitacreTheme.separator(colorScheme)).frame(height: 1).padding(.leading, 11)
        }
    }
}
