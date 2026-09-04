import AppKit
import GitacreCore
import SwiftUI
import UniformTypeIdentifiers

struct RepositoryListView: View {
    @EnvironmentObject private var model: AppModel
    let showsPendingOnly: Bool
    @Binding var selectedRepositoryID: String?
    @Binding var expandedRepositoryIDs: Set<String>
    var emptyAction: (() -> Void)?

    private var sections: [RepositorySection] {
        if showsPendingOnly {
            return [
                RepositorySection(title: "UNCOMMITTED", repositories: model.repositories.filter { $0.hasUncommittedWork }),
                RepositorySection(title: "AHEAD OF REMOTE", repositories: model.repositories.filter { !$0.hasUncommittedWork && $0.totalAhead > 0 }),
                RepositorySection(title: "STASHED", repositories: model.repositories.filter { !$0.hasUncommittedWork && $0.totalAhead == 0 && $0.stashCount > 0 })
            ].filter { !$0.repositories.isEmpty }
        }

        let active = model.repositories.filter(\.hasPendingWork)
        let clean = model.repositories.filter { !$0.hasPendingWork }
        return [
            RepositorySection(title: "ACTIVE", repositories: active),
            RepositorySection(title: "CLEAN", repositories: clean)
        ].filter { !$0.repositories.isEmpty }
    }

    var body: some View {
        Group {
            if model.isLoadingRepositories && !model.hasLoadedRepositories {
                FirstScanView()
            } else if model.roots.isEmpty {
                EmptyStateView(
                    symbol: "folder",
                    title: "No repositories yet",
                    message: "Point gitacre at the folders where you keep your work. It reads Git state locally and never writes to your repositories.",
                    actionTitle: "Add a folder…",
                    action: model.addRepositoryRoot
                )
                .overlay(alignment: .bottom) {
                    Text("or drop a folder onto this panel")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 28)
                }
                .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: acceptDroppedFolders)
            } else if showsPendingOnly && model.pendingRepositories.isEmpty {
                EmptyStateView(
                    symbol: "checkmark",
                    title: "Everything is committed",
                    message: "All \(model.repositories.count) repositories are clean and in sync with their remotes.",
                    actionTitle: "View all repositories",
                    action: emptyAction
                )
            } else if model.repositories.isEmpty {
                EmptyStateView(
                    symbol: "folder",
                    title: "No repositories found",
                    message: "Try another monitored folder or increase the maximum search depth in Settings.",
                    actionTitle: "Add a folder…",
                    action: model.addRepositoryRoot
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sections) { section in
                            RepositorySectionView(
                                section: section,
                                selectedRepositoryID: $selectedRepositoryID,
                                expandedRepositoryIDs: $expandedRepositoryIDs
                            )
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private func acceptDroppedFolders(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let path = url?.path else { return }
                Task { @MainActor in model.addRepositoryRoots([path]) }
            }
        }
        return accepted
    }
}

private struct RepositorySection: Identifiable {
    let title: String
    let repositories: [Repository]
    var id: String { title }
}

private struct RepositorySectionView: View {
    let section: RepositorySection
    @Binding var selectedRepositoryID: String?
    @Binding var expandedRepositoryIDs: Set<String>

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(section.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.66)
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .frame(height: 27, alignment: .bottom)
            .padding(.bottom, 5)

            ForEach(Array(section.repositories.enumerated()), id: \.element.id) { index, repository in
                RepositoryRow(
                    repository: repository,
                    selected: selectedRepositoryID == repository.id,
                    expanded: expandedRepositoryIDs.contains(repository.id),
                    onSelect: { selectedRepositoryID = repository.id },
                    onToggleExpansion: {
                        selectedRepositoryID = repository.id
                        if expandedRepositoryIDs.contains(repository.id) {
                            expandedRepositoryIDs.remove(repository.id)
                        } else {
                            expandedRepositoryIDs.insert(repository.id)
                        }
                    }
                )

                if index < section.repositories.count - 1 {
                    Hairline().padding(.horizontal, 10).padding(.leading, 35)
                }
            }
        }
    }
}

private struct RepositoryRow: View {
    let repository: Repository
    let selected: Bool
    let expanded: Bool
    let onSelect: () -> Void
    let onToggleExpansion: () -> Void
    @State private var hovered = false

    private var worktree: Worktree? {
        repository.worktrees.first(where: \.isPrimary) ?? repository.worktrees.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if repository.worktrees.count > 1 {
                    Button(action: onToggleExpansion) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 11, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(expanded ? "Collapse worktrees" : "Expand worktrees")
                } else {
                    Color.clear.frame(width: 11, height: 1)
                }

                RepositoryGlyph(repository: repository, status: repositoryStatusRole)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(repository.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .layoutPriority(2)

                        if let worktree {
                            BranchChip(branch: worktree.branch, detached: worktree.isDetached)
                        }
                        Spacer(minLength: 0)
                    }

                    RepositoryStatusLine(repository: repository, worktree: worktree)
                }

                RepositoryActions(repository: repository, worktree: worktree, emphasized: hovered || selected)
            }
            .padding(.horizontal, 5)
            .frame(minHeight: 47)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                onSelect()
                if repository.worktrees.count > 1 { onToggleExpansion() }
            }
            .onHover { value in
                withAnimation(.easeOut(duration: 0.09)) { hovered = value }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(repositoryAccessibilityLabel)

            if expanded && repository.worktrees.count > 1 {
                WorktreeChildren(repository: repository)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: expanded)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var rowBackground: Color {
        if selected { return GitacreTheme.selected(colorScheme) }
        if hovered { return GitacreTheme.hover(colorScheme) }
        return .clear
    }

    private var repositoryStatusRole: StatusRole {
        if repository.worktrees.contains(where: { $0.operation != nil || $0.conflicted > 0 }) { return .blocked }
        if repository.hasPendingWork { return .drift }
        return .clean
    }

    private var repositoryAccessibilityLabel: String {
        let branch = worktree?.branch ?? "unknown branch"
        return "\(repository.name), \(branch), \(repositoryStatusText(repository: repository, worktree: worktree))"
    }
}

private struct WorktreeChildren: View {
    let repository: Repository

    private let rowHeight: CGFloat = 41
    private let separatorHeight: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(repository.worktrees.enumerated()), id: \.element.id) { index, worktree in
                WorktreeRow(repository: repository, worktree: worktree)
                if index < repository.worktrees.count - 1 {
                    Hairline().padding(.leading, 18).padding(.trailing, 10)
                }
            }
        }
        .padding(.leading, 45)
        .overlay {
            Canvas { context, _ in
                let trunkX: CGFloat = 10.5
                let firstRowCenter = rowHeight / 2
                let rowStride = rowHeight + separatorHeight
                let lastRowCenter = firstRowCenter + CGFloat(max(repository.worktrees.count - 1, 0)) * rowStride

                var connectors = Path()
                connectors.move(to: CGPoint(x: trunkX, y: 0))
                connectors.addLine(to: CGPoint(x: trunkX, y: lastRowCenter))

                for index in repository.worktrees.indices {
                    let centerY = firstRowCenter + CGFloat(index) * rowStride
                    connectors.move(to: CGPoint(x: trunkX, y: centerY))
                    connectors.addLine(to: CGPoint(x: 48, y: centerY))
                }

                context.stroke(
                    connectors,
                    with: .color(Color.secondary.opacity(0.19)),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                )
            }
            .allowsHitTesting(false)
        }
    }
}

private struct WorktreeRow: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    let worktree: Worktree
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(worktree.branch)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    if worktree.isPrimary {
                        Text("PRIMARY")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    Text(relativeWorktreePath(worktree.path, repository: repository))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text("·")
                    Text(repositoryStatusText(repository: nil, worktree: worktree))
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 1) {
                InlineActionIcon(symbol: "folder", label: "Reveal \(worktree.branch) in Finder", emphasized: hovered) {
                    model.reveal(worktree.path)
                }
                InlineActionIcon(symbol: "apple.terminal", fallback: "terminal", label: "Open in \(terminalName)", emphasized: hovered) {
                    model.openTerminal(at: worktree.path)
                }
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 41)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private var terminalName: String { model.selectedTerminalApplication?.name ?? "Terminal" }
}

struct RepositoryGlyph: View {
    let repository: Repository
    let status: StatusRole
    @Environment(\.colorScheme) private var colorScheme

    private var image: NSImage? { repository.iconPath.flatMap(NSImage.init(contentsOfFile:)) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(image == nil ? status.color(colorScheme).opacity(0.10) : Color.clear)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                BranchMark(strokeColor: GitacreTheme.tertiaryInk(colorScheme), lineWidth: 1.25)
                    .padding(4)
            }
        }
        .frame(width: 19, height: 19)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(GitacreTheme.hairline(colorScheme), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

private struct BranchChip: View {
    let branch: String
    let detached: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(detached ? "detached · \(branch)" : branch)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(GitacreTheme.secondaryInk(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .frame(width: branchChipWidth, height: 16)
            .background(GitacreTheme.surfaceSunk(colorScheme), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .clipped()
    }

    private var branchChipWidth: CGFloat {
        min(max(CGFloat((detached ? "detached · " : "").count + branch.count) * 6 + 14, 38), 150)
    }
}

private struct RepositoryStatusLine: View {
    let repository: Repository
    let worktree: Worktree?

    var body: some View {
        HStack(spacing: 4) {
            StatusFactsView(facts: statusFacts(repository: repository, worktree: worktree))
            if let date = worktree?.lastCommitDate {
                Text("·").foregroundStyle(.tertiary)
                Text(compactRelativeDate(date)).foregroundStyle(.tertiary).fixedSize()
            }
            if repository.worktrees.count > 1 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(repository.worktrees.count) worktrees").foregroundStyle(.tertiary).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
    }
}

private struct RepositoryActions: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    let worktree: Worktree?
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 1) {
            if let worktree {
                InlineActionIcon(symbol: "folder", label: "Reveal in Finder", emphasized: emphasized) {
                    model.reveal(worktree.path)
                }
                InlineActionIcon(symbol: "apple.terminal", fallback: "terminal", label: "Open in \(terminalName)", emphasized: emphasized) {
                    model.openTerminal(at: worktree.path)
                }
            }
            if let remoteURL = repository.remoteURL {
                InlineActionIcon(symbol: "arrow.up.right", label: "Open remote", emphasized: emphasized) {
                    model.open(remoteURL)
                }
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .fixedSize()
    }

    private var terminalName: String { model.selectedTerminalApplication?.name ?? "Terminal" }
}

struct InlineActionIcon: View {
    let symbol: String
    var fallback: String? = nil
    let label: String
    let emphasized: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: availableSymbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle((hovered || emphasized) ? GitacreTheme.primaryInk(colorScheme) : GitacreTheme.tertiaryInk(colorScheme))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { value in withAnimation(.easeOut(duration: 0.09)) { hovered = value } }
        .help(label)
        .accessibilityLabel(label)
    }

    private var availableSymbol: String {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? (fallback ?? symbol) : symbol
    }
}

enum StatusRole {
    case clean, drift, blocked, secondary

    func color(_ scheme: ColorScheme) -> Color {
        switch self {
        case .clean: GitacreTheme.clean(scheme)
        case .drift: GitacreTheme.drift(scheme)
        case .blocked: GitacreTheme.blocked(scheme)
        case .secondary: GitacreTheme.secondaryInk(scheme)
        }
    }
}

struct StatusFact: Identifiable {
    let text: String
    let role: StatusRole
    var id: String { text }
}

struct StatusFactsView: View {
    let facts: [StatusFact]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(facts.prefix(3).enumerated()), id: \.offset) { index, fact in
                if index > 0 { Text("·").foregroundStyle(.tertiary) }
                Text(fact.text).foregroundStyle(fact.role.color(colorScheme))
            }
        }
    }
}

func statusFacts(repository: Repository?, worktree: Worktree?) -> [StatusFact] {
    guard let worktree else {
        if let repository, repository.stashCount > 0 { return [StatusFact(text: "\(repository.stashCount) stashed", role: .drift)] }
        return [StatusFact(text: "clean · in sync", role: .clean)]
    }
    var facts: [StatusFact] = []
    if let operation = worktree.operation { facts.append(StatusFact(text: "\(operation.displayName) in progress", role: .blocked)) }
    if worktree.conflicted > 0 { facts.append(StatusFact(text: "\(worktree.conflicted) conflict\(worktree.conflicted == 1 ? "" : "s")", role: .blocked)) }
    if worktree.staged > 0 { facts.append(StatusFact(text: "\(worktree.staged) staged", role: .secondary)) }
    if worktree.unstaged > 0 { facts.append(StatusFact(text: "\(worktree.unstaged) modified", role: .secondary)) }
    if worktree.untracked > 0 { facts.append(StatusFact(text: "\(worktree.untracked) untracked", role: .secondary)) }
    if worktree.ahead > 0 { facts.append(StatusFact(text: "\(worktree.ahead) ahead", role: .drift)) }
    if worktree.behind > 0 { facts.append(StatusFact(text: "\(worktree.behind) behind", role: .drift)) }
    if let repository, repository.stashCount > 0 { facts.append(StatusFact(text: "\(repository.stashCount) stashed", role: .drift)) }
    return facts.isEmpty ? [StatusFact(text: "clean · in sync", role: .clean)] : facts
}

func repositoryStatusText(repository: Repository?, worktree: Worktree?) -> String {
    statusFacts(repository: repository, worktree: worktree).prefix(3).map(\.text).joined(separator: " · ")
}

private func relativeWorktreePath(_ path: String, repository: Repository) -> String {
    let primaryPath = repository.worktrees.first(where: \.isPrimary)?.path
    if path == primaryPath { return (path as NSString).abbreviatingWithTildeInPath }
    return "../\(URL(fileURLWithPath: path).lastPathComponent)"
}

func compactRelativeDate(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    switch seconds {
    case ..<60: return "now"
    case ..<3_600: return "\(seconds / 60)m"
    case ..<86_400: return "\(seconds / 3_600)h"
    case ..<172_800: return "yesterday"
    case ..<31_536_000: return "\(seconds / 86_400)d"
    default: return "\(seconds / 31_536_000)y"
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(GitacreTheme.surfaceSunk(colorScheme))
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GitacreTheme.tertiaryInk(colorScheme))
            }
            .frame(width: 34, height: 34)
            .padding(.bottom, 2)

            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(QuietButtonStyle())
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct FirstScanView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 5).fill(GitacreTheme.surfaceSunk(colorScheme)).frame(width: 19, height: 19)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(GitacreTheme.surfaceSunk(colorScheme)).frame(width: 116 + CGFloat(index % 3) * 19, height: 8)
                        RoundedRectangle(cornerRadius: 2).fill(GitacreTheme.surfaceSunk(colorScheme).opacity(0.7)).frame(width: 176, height: 7)
                    }
                    Spacer()
                }
                .padding(.horizontal, 15)
                .frame(height: 47)
            }
            Text("Cached results appear immediately on later launches; only changed repositories are re-read.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .padding(.top, 16)
            Spacer()
        }
        .padding(.top, 8)
    }
}
