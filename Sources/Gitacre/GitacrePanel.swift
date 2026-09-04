import AppKit
import GitacreCore
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case pending
    case all
    case pullRequests

    var id: Self { self }
    var title: String {
        switch self {
        case .pending: "Pending"
        case .all: "All"
        case .pullRequests: "PRs"
        }
    }
}

struct GitacrePanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @State private var selectedTab = PanelTab.pending
    @State private var didResolveDefaultTab = false
    @State private var selectedRepositoryID: String?
    @State private var selectedPullRequestID: String?
    @State private var expandedRepositoryIDs = Set(UserDefaults.standard.stringArray(forKey: "expandedRepositoryIDs") ?? [])

    var body: some View {
        VStack(spacing: 0) {
            header
            navigation

            Group {
                switch selectedTab {
                case .pending:
                    RepositoryListView(
                        showsPendingOnly: true,
                        selectedRepositoryID: $selectedRepositoryID,
                        expandedRepositoryIDs: $expandedRepositoryIDs,
                        emptyAction: { selectedTab = .all }
                    )
                case .all:
                    RepositoryListView(
                        showsPendingOnly: false,
                        selectedRepositoryID: $selectedRepositoryID,
                        expandedRepositoryIDs: $expandedRepositoryIDs
                    )
                case .pullRequests:
                    PullRequestListView(selectedPullRequestID: $selectedPullRequestID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 392, height: 540)
        .background(GitacreTheme.surface(colorScheme))
        .tint(GitacreTheme.accent(colorScheme))
        .preferredColorScheme(model.appearance.colorScheme)
        .background(PanelKeyboardMonitor(handler: handleKeyboardAction))
        .onAppear {
            resolveDefaultTabIfPossible()
            ensureSelection()
        }
        .onChange(of: model.hasLoadedRepositories) { _, loaded in
            if loaded { resolveDefaultTabIfPossible(); ensureSelection() }
        }
        .onChange(of: selectedTab) { _, _ in ensureSelection() }
        .onChange(of: expandedRepositoryIDs) { _, ids in
            UserDefaults.standard.set(Array(ids), forKey: "expandedRepositoryIDs")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark(size: 19)

            VStack(alignment: .leading, spacing: 1) {
                Text("gitacre")
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(-0.15)
                Text(headerSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(GitacreTheme.tertiaryInk(colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if model.attentionCount > 0 {
                Text("\(model.attentionCount)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(GitacreTheme.accent(colorScheme))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(GitacreTheme.selected(colorScheme), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("\(model.attentionCount) items need attention")
            }

            Button(action: refreshSelectedTab) {
                Image(systemName: "arrow.clockwise")
                    .opacity(isRefreshingSelectedTab ? 0.45 : 1)
            }
            .buttonStyle(QuietIconButtonStyle())
            .disabled(isRefreshingSelectedTab)
            .help("Refresh \(selectedTab.title)")
            .accessibilityLabel("Refresh \(selectedTab.title)")
        }
        .padding(.horizontal, 11)
        .frame(height: 51)
        .background(GitacreTheme.chrome(colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(GitacreTheme.hairline(colorScheme)).frame(height: 0.5)
        }
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            ForEach(PanelTab.allCases) { tab in tabButton(tab) }
        }
        .padding(2)
        .frame(height: 27)
        .background(GitacreTheme.surfaceSunk(colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 5)
    }

    private func tabButton(_ tab: PanelTab) -> some View {
        let selected = selectedTab == tab
        let disabled = tab == .pending && model.hasLoadedRepositories && model.pendingCount == 0 && !selected

        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Text(tab.title)
                if tab == .pullRequests && !model.visiblePullRequests.isEmpty {
                    Text("\(model.visiblePullRequests.count)").monospacedDigit().foregroundStyle(.tertiary)
                }
                if tab == .pullRequests, model.githubSnapshot.errorMessage != nil {
                    Circle().fill(GitacreTheme.blocked(colorScheme)).frame(width: 5, height: 5)
                }
            }
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(disabled ? GitacreTheme.tertiaryInk(colorScheme) : GitacreTheme.primaryInk(colorScheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(GitacreTheme.segmentSelection(colorScheme))
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 1.5, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(githubStatusColor).frame(width: 5, height: 5)
            Text(githubStatusText)
                .font(.system(size: 9.5))
                .foregroundStyle(GitacreTheme.secondaryInk(colorScheme))
                .lineLimit(1)
            Spacer()
            Button("Settings", action: onOpenSettings)
                .buttonStyle(.plain)
                .font(.system(size: 9.5))
                .foregroundStyle(GitacreTheme.secondaryInk(colorScheme))
                .keyboardShortcut(",", modifiers: .command)
            Button("Quit", action: onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 9.5))
                .foregroundStyle(GitacreTheme.secondaryInk(colorScheme))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(GitacreTheme.chrome(colorScheme))
        .overlay(alignment: .top) {
            Rectangle().fill(GitacreTheme.hairline(colorScheme)).frame(height: 0.5)
        }
    }

    private var headerSubtitle: String {
        if selectedTab != .pullRequests && model.isLoadingRepositories {
            return "Scanning \(model.roots.count) folder\(model.roots.count == 1 ? "" : "s")…"
        }
        if selectedTab == .pullRequests && model.isLoadingGitHub { return "Checking GitHub…" }
        switch selectedTab {
        case .pending:
            if model.roots.isEmpty { return "No folders monitored" }
            if model.pendingCount == 0 { return "\(model.repositories.count) repositories · nothing pending" }
            return "\(model.repositories.count) repositories · \(updatedText)"
        case .all:
            let worktrees = model.repositories.reduce(0) { $0 + $1.worktrees.count }
            return "\(model.repositories.count) repositories · \(worktrees) worktrees"
        case .pullRequests:
            switch model.githubSnapshot.authentication {
            case .signedIn:
                let authored = model.visiblePullRequests.filter { $0.kind == .authored }.count
                return "\(model.reviewCount) awaiting your review · \(authored) opened by you"
            case .cliMissing: return "GitHub CLI required"
            case .signedOut: return "GitHub sign-in required"
            case .unavailable: return "GitHub temporarily unavailable"
            }
        }
    }

    private var updatedText: String {
        guard let date = model.lastRepositoryRefresh else { return "not yet scanned" }
        if Date().timeIntervalSince(date) < 60 { return "updated just now" }
        return "updated \(compactRelativeDate(date)) ago"
    }

    private var githubStatusText: String {
        switch model.githubSnapshot.authentication {
        case .cliMissing: "gh · not installed"
        case .signedOut: "gh · not authenticated"
        case let .signedIn(_, login): "gh · connected as \(login)"
        case .unavailable: "gh · unavailable"
        }
    }

    private var githubStatusColor: Color {
        switch model.githubSnapshot.authentication {
        case .signedIn: GitacreTheme.clean(colorScheme)
        case .signedOut, .unavailable: GitacreTheme.drift(colorScheme)
        case .cliMissing: GitacreTheme.tertiaryInk(colorScheme)
        }
    }

    private var isRefreshingSelectedTab: Bool {
        selectedTab == .pullRequests ? model.isLoadingGitHub : model.isLoadingRepositories
    }

    private func refreshSelectedTab() {
        Task {
            if selectedTab == .pullRequests { await model.refreshGitHub() }
            else { await model.refreshRepositories() }
        }
    }

    private func resolveDefaultTabIfPossible() {
        guard !didResolveDefaultTab, model.hasLoadedRepositories else { return }
        selectedTab = model.pendingCount > 0 ? .pending : .all
        didResolveDefaultTab = true
    }

    private var orderedRepositories: [Repository] {
        if selectedTab == .all { return model.repositories }
        let uncommitted = model.repositories.filter(\.hasUncommittedWork)
        let ahead = model.repositories.filter { !$0.hasUncommittedWork && $0.totalAhead > 0 }
        let stashed = model.repositories.filter { !$0.hasUncommittedWork && $0.totalAhead == 0 && $0.stashCount > 0 }
        return uncommitted + ahead + stashed
    }

    private func ensureSelection() {
        if selectedTab == .pullRequests {
            if !model.visiblePullRequests.contains(where: { $0.id == selectedPullRequestID }) {
                selectedPullRequestID = model.visiblePullRequests.first?.id
            }
        } else if !orderedRepositories.contains(where: { $0.id == selectedRepositoryID }) {
            selectedRepositoryID = orderedRepositories.first?.id
        }
    }

    private func handleKeyboardAction(_ action: PanelKeyboardAction) -> Bool {
        switch action {
        case .tab(let index):
            guard PanelTab.allCases.indices.contains(index) else { return false }
            let tab = PanelTab.allCases[index]
            if tab == .pending && model.pendingCount == 0 { selectedTab = .all }
            else { selectedTab = tab }
        case .refresh: refreshSelectedTab()
        case .escape: NotificationCenter.default.post(name: .closeGitacrePanel, object: nil)
        case .move(let delta): moveSelection(delta)
        case .expand: setSelectedRepositoryExpanded(true)
        case .collapse: setSelectedRepositoryExpanded(false)
        case .primary: performPrimaryAction()
        case .terminal: performTerminalAction()
        case .remote: performRemoteAction()
        }
        return true
    }

    private func moveSelection(_ delta: Int) {
        if selectedTab == .pullRequests {
            let rows = model.visiblePullRequests
            guard !rows.isEmpty else { return }
            let current = rows.firstIndex { $0.id == selectedPullRequestID } ?? (delta > 0 ? -1 : rows.count)
            selectedPullRequestID = rows[min(max(current + delta, 0), rows.count - 1)].id
        } else {
            let rows = orderedRepositories
            guard !rows.isEmpty else { return }
            let current = rows.firstIndex { $0.id == selectedRepositoryID } ?? (delta > 0 ? -1 : rows.count)
            selectedRepositoryID = rows[min(max(current + delta, 0), rows.count - 1)].id
        }
    }

    private func setSelectedRepositoryExpanded(_ expanded: Bool) {
        guard selectedTab != .pullRequests,
              let id = selectedRepositoryID,
              let repository = model.repositories.first(where: { $0.id == id }),
              repository.worktrees.count > 1 else { return }
        if expanded { expandedRepositoryIDs.insert(id) }
        else { expandedRepositoryIDs.remove(id) }
    }

    private func performPrimaryAction() {
        if selectedTab == .pullRequests {
            if let row = model.visiblePullRequests.first(where: { $0.id == selectedPullRequestID }) { model.open(row.url) }
        } else if let repository = selectedRepository, let path = primaryWorktree(repository)?.path {
            model.reveal(path)
        }
    }

    private func performTerminalAction() {
        if let repository = selectedRepository, let path = primaryWorktree(repository)?.path { model.openTerminal(at: path) }
    }

    private func performRemoteAction() {
        if selectedTab == .pullRequests { performPrimaryAction() }
        else if let url = selectedRepository?.remoteURL { model.open(url) }
    }

    private var selectedRepository: Repository? {
        model.repositories.first { $0.id == selectedRepositoryID }
    }

    private func primaryWorktree(_ repository: Repository) -> Worktree? {
        repository.worktrees.first(where: \.isPrimary) ?? repository.worktrees.first
    }
}

enum PanelKeyboardAction {
    case tab(Int)
    case refresh
    case escape
    case move(Int)
    case expand
    case collapse
    case primary
    case terminal
    case remote
}

private struct PanelKeyboardMonitor: NSViewRepresentable {
    let handler: (PanelKeyboardAction) -> Bool

    func makeNSView(context: Context) -> PanelKeyboardView {
        let view = PanelKeyboardView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: PanelKeyboardView, context: Context) { nsView.handler = handler }
}

private final class PanelKeyboardView: NSView {
    var handler: ((PanelKeyboardAction) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.window === event.window, let action = Self.action(for: event), self?.handler?(action) == true else { return event }
            return nil
        }
    }

    private static func action(for event: NSEvent) -> PanelKeyboardAction? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let characters = event.charactersIgnoringModifiers {
            if characters == "1" { return .tab(0) }
            if characters == "2" { return .tab(1) }
            if characters == "3" { return .tab(2) }
            if characters.lowercased() == "r" { return .refresh }
            if event.keyCode == 36 { return flags.contains(.shift) ? .remote : .terminal }
        }
        if event.keyCode == 53 { return .escape }
        if event.keyCode == 125 { return .move(1) }
        if event.keyCode == 126 { return .move(-1) }
        if event.keyCode == 124 { return .expand }
        if event.keyCode == 123 { return .collapse }
        if event.keyCode == 36 { return .primary }
        return nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
