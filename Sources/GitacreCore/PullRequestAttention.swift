import Foundation

public struct RepositoryIdentity: Hashable, Codable, Sendable {
    public let host: String
    public let owner: String
    public let name: String

    public init?(url: URL?) {
        guard let url, let host = url.host else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        self.host = host.lowercased()
        self.owner = parts[0].lowercased()
        let name = String(parts[1])
        self.name = (name.hasSuffix(".git") ? String(name.dropLast(4)) : name).lowercased()
    }
}

public struct PullRequestDetails: Codable, Equatable, Sendable {
    public struct HeadRepository: Codable, Equatable, Sendable {
        public let nameWithOwner: String?
    }
    public struct Check: Codable, Equatable, Sendable {
        public let status: String?
        public let conclusion: String?
        public let state: String?
    }
    public let headRefName: String
    public let headRefOid: String
    public let headRepository: HeadRepository?
    public let baseRefName: String
    public let reviewDecision: String?
    public let mergeStateStatus: String?
    public let mergeable: String?
    public let statusCheckRollup: [Check]?

    public var checksFailing: Bool {
        (statusCheckRollup ?? []).contains {
            ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains($0.conclusion ?? $0.state ?? "")
        }
    }
    public var checksPending: Bool {
        (statusCheckRollup ?? []).contains {
            if let status = $0.status { return status != "COMPLETED" }
            return ["PENDING", "EXPECTED"].contains($0.state ?? "")
        }
    }
    public var checksGreen: Bool {
        guard let checks = statusCheckRollup, !checks.isEmpty else { return false }
        return checks.allSatisfy { ["SUCCESS", "NEUTRAL", "SKIPPED"].contains($0.conclusion ?? $0.state ?? "") }
    }
}

extension PullRequest {
    public var repositoryIdentity: RepositoryIdentity? { RepositoryIdentity(url: url) }

    public var attentionReasons: [String] {
        var reasons: [String] = []
        if kind == .reviewRequested { reasons.append("Review requested") }
        guard let details else { return reasons }
        if details.checksFailing { reasons.append("Checks failing") }
        else if details.checksPending { reasons.append("Checks pending") }
        if details.reviewDecision == "CHANGES_REQUESTED" { reasons.append("Changes requested") }
        if details.mergeable == "CONFLICTING" { reasons.append("Merge conflicts") }
        if !isDraft, details.reviewDecision == "APPROVED", details.checksGreen,
           details.mergeable == "MERGEABLE", details.mergeStateStatus == "CLEAN" {
            reasons.append("Ready to merge")
        }
        return reasons
    }

    public var attentionSummary: String {
        let reasons = attentionReasons
        let text = reasons.isEmpty ? (details == nil ? "Status not loaded" : "No action indicated") : reasons.joined(separator: " · ")
        return detailsAreStale ? text + " · cached" : text
    }

    public var detailsAreStale: Bool {
        guard let detailsFetchedAt else { return details != nil }
        return Date().timeIntervalSince(detailsFetchedAt) > 600 || detailsFetchedAt < updatedAt
    }

    public func matchingWorktrees(in repositories: [Repository]) -> [Worktree] {
        guard let details, let base = repositoryIdentity else { return [] }
        let head = details.headRepository?.nameWithOwner.flatMap { RepositoryIdentity(url: URL(string: "https://\(base.host)/\($0)")) }
        let candidates = repositories.filter {
            guard let identity = RepositoryIdentity(url: $0.remoteURL) else { return false }
            return identity == base || identity == head
        }.flatMap(\.worktrees)
        let shaMatches = candidates.filter { !details.headRefOid.isEmpty && $0.head == details.headRefOid }
        if !shaMatches.isEmpty { return shaMatches }
        // Branch matching must use the head repository, never the base of a fork PR.
        return repositories.filter { RepositoryIdentity(url: $0.remoteURL) == head && head != nil }
            .flatMap(\.worktrees).filter { !$0.isDetached && $0.branch == details.headRefName }
    }
}
