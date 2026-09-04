import GitacreCore
import SwiftUI

struct PullRequestListView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedPullRequestID: String?

    private var reviewRequests: [PullRequest] {
        model.visiblePullRequests.filter { $0.kind == .reviewRequested }
    }

    private var authored: [PullRequest] {
        model.visiblePullRequests.filter { $0.kind == .authored }
    }

    var body: some View {
        Group {
            switch model.githubSnapshot.authentication {
            case .cliMissing:
                authenticationFailure(
                    title: "GitHub CLI is not installed",
                    message: "Install gh to see pull requests. Local repository state is unaffected.",
                    primaryTitle: "Open Terminal",
                    primaryAction: { model.copyAndOpenTerminal("brew install gh") }
                )
            case .signedOut:
                authenticationFailure(
                    title: "GitHub CLI is not authenticated",
                    message: "gitacre reuses your gh session. Run gh auth login and refresh. Local repository state is unaffected.",
                    primaryTitle: "Open Terminal",
                    primaryAction: { model.copyAndOpenTerminal("gh auth login --hostname github.com") }
                )
            case let .unavailable(_, message):
                authenticationFailure(
                    title: "GitHub is temporarily unavailable",
                    message: message,
                    primaryTitle: "Retry",
                    primaryAction: { Task { await model.refreshGitHub() } }
                )
            case .signedIn:
                signedInView
            }
        }
    }

    private var signedInView: some View {
        Group {
            if model.isLoadingGitHub && model.githubSnapshot.fetchedAt == nil {
                FirstPRScanView()
            } else if reviewRequests.isEmpty && authored.isEmpty && model.githubSnapshot.errorMessage == nil {
                EmptyStateView(
                    symbol: "checkmark",
                    title: "No open pull requests",
                    message: "There are no review requests or open pull requests matching your filters.",
                    actionTitle: "Refresh",
                    action: { Task { await model.refreshGitHub() } }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let error = model.githubSnapshot.errorMessage {
                            InlineErrorBanner(
                                title: "Showing cached pull requests",
                                message: error,
                                primaryTitle: "Retry",
                                primaryAction: { Task { await model.refreshGitHub() } }
                            )
                            .padding(.horizontal, 5)
                            .padding(.top, 6)
                        }
                        if !reviewRequests.isEmpty {
                            PullRequestSection(
                                title: "NEEDS YOUR REVIEW",
                                pullRequests: reviewRequests,
                                selectedPullRequestID: $selectedPullRequestID
                            )
                        }
                        if !authored.isEmpty {
                            PullRequestSection(
                                title: "OPENED BY YOU",
                                pullRequests: authored,
                                selectedPullRequestID: $selectedPullRequestID
                            )
                        }
                        Text("Review requests and your open PRs, via the signed-in gh session. Click a row to open it on GitHub.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 12)
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private func authenticationFailure(
        title: String,
        message: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void
    ) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                InlineErrorBanner(
                    title: title,
                    message: message,
                    primaryTitle: primaryTitle,
                    primaryAction: primaryAction
                )
                .padding(.horizontal, 5)
                .padding(.top, 6)

                if !model.pendingRepositories.isEmpty {
                    HStack {
                        Text("LOCAL WORK CONTINUES")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.66)
                        Spacer()
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 15)
                    .padding(.top, 15)
                    .padding(.bottom, 5)

                    ForEach(model.pendingRepositories.prefix(4)) { repository in
                        LocalFallbackRow(repository: repository)
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
    }
}

private struct PullRequestSection: View {
    let title: String
    let pullRequests: [PullRequest]
    @Binding var selectedPullRequestID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.66)
                Text("\(pullRequests.count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .frame(height: 32, alignment: .bottom)
            .padding(.bottom, 5)

            ForEach(Array(pullRequests.enumerated()), id: \.element.id) { index, pullRequest in
                PullRequestRow(
                    pullRequest: pullRequest,
                    selected: selectedPullRequestID == pullRequest.id,
                    onSelect: { selectedPullRequestID = pullRequest.id }
                )
                if index < pullRequests.count - 1 {
                    Hairline().padding(.horizontal, 10).padding(.leading, 35)
                }
            }
        }
        .padding(.horizontal, 5)
    }
}

private struct PullRequestRow: View {
    @EnvironmentObject private var model: AppModel
    let pullRequest: PullRequest
    let selected: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    private var repository: Repository? {
        let shortName = pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository
        return model.repositories.first { $0.name.caseInsensitiveCompare(shortName) == .orderedSame }
    }

    var body: some View {
        Button {
            onSelect()
            model.open(pullRequest.url)
        } label: {
            HStack(spacing: 9) {
                pullRequestGlyph

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(pullRequest.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(GitacreTheme.primaryInk(colorScheme))
                            .lineLimit(1)
                        if pullRequest.isDraft {
                            Text("DRAFT")
                                .font(.system(size: 8, weight: .semibold))
                                .tracking(0.35)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .frame(height: 15)
                                .background(GitacreTheme.surfaceSunk(colorScheme), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 4) {
                        Text(shortRepositoryName).fontWeight(.medium)
                        Text("#\(pullRequest.number)")
                        if pullRequest.kind == .reviewRequested && !pullRequest.author.isEmpty {
                            Text("·")
                            Text(pullRequest.author)
                        }
                        Text("·")
                        Text(compactRelativeDate(pullRequest.updatedAt))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(GitacreTheme.secondaryInk(colorScheme))
                    .lineLimit(1)
                }

                if pullRequest.comments > 0 {
                    VStack(spacing: 1) {
                        Image(systemName: "bubble")
                        Text("\(pullRequest.comments)").monospacedDigit()
                    }
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(hovered ? GitacreTheme.primaryInk(colorScheme) : GitacreTheme.tertiaryInk(colorScheme))
            }
            .padding(.horizontal, 5)
            .frame(minHeight: 49)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { value in withAnimation(.easeOut(duration: 0.09)) { hovered = value } }
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Open on GitHub")
    }

    @ViewBuilder
    private var pullRequestGlyph: some View {
        if let repository {
            RepositoryGlyph(repository: repository, status: pullRequest.kind == .reviewRequested ? .drift : .secondary)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(GitacreTheme.surfaceSunk(colorScheme))
                Text(String(shortRepositoryName.prefix(1)).uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 19, height: 19)
        }
    }

    private var rowBackground: Color {
        selected ? GitacreTheme.selected(colorScheme) : (hovered ? GitacreTheme.hover(colorScheme) : .clear)
    }

    private var shortRepositoryName: String {
        pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository
    }

    private var accessibilityDescription: String {
        var parts = ["Pull request \(pullRequest.number)", pullRequest.title, "in \(pullRequest.repository)"]
        if pullRequest.isDraft { parts.append("draft") }
        if pullRequest.comments > 0 { parts.append("\(pullRequest.comments) comments") }
        return parts.joined(separator: ", ")
    }
}

struct InlineErrorBanner: View {
    let title: String
    let message: String
    let primaryTitle: String
    let primaryAction: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GitacreTheme.blocked(colorScheme))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(primaryTitle, action: primaryAction).buttonStyle(QuietButtonStyle())
                Button("Retry") { Task { await model.refreshGitHub() } }
                    .buttonStyle(QuietButtonStyle())
                    .opacity(primaryTitle == "Retry" ? 0 : 1)
                    .frame(width: primaryTitle == "Retry" ? 0 : nil)
                Spacer()
            }
        }
        .padding(10)
        .background(GitacreTheme.surfaceSunk(colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(GitacreTheme.hairline(colorScheme), lineWidth: 0.5)
        }
    }

    @EnvironmentObject private var model: AppModel
}

private struct LocalFallbackRow: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository

    private var worktree: Worktree? { repository.worktrees.first(where: \.isPrimary) ?? repository.worktrees.first }

    var body: some View {
        HStack(spacing: 9) {
            RepositoryGlyph(repository: repository, status: .drift)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(repository.name).font(.system(size: 12.5, weight: .semibold))
                    if let worktree {
                        Text(worktree.branch).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text(repositoryStatusText(repository: repository, worktree: worktree))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let worktree {
                InlineActionIcon(symbol: "folder", label: "Reveal in Finder", emphasized: false) { model.reveal(worktree.path) }
                InlineActionIcon(symbol: "apple.terminal", fallback: "terminal", label: "Open in Terminal", emphasized: false) { model.openTerminal(at: worktree.path) }
            }
        }
        .frame(height: 47)
    }
}

private struct FirstPRScanView: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.10)).frame(width: 19, height: 19)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.10)).frame(width: 210 + CGFloat(index % 2) * 32, height: 8)
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.07)).frame(width: 130, height: 7)
                    }
                    Spacer()
                }
                .padding(.horizontal, 15)
                .frame(height: 49)
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}
