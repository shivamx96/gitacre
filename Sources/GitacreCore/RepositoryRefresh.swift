import Foundation

public struct ScanConfiguration: Equatable, Sendable {
    public var roots: [String]
    public var maximumDepth: Int
    public var includeLinkedWorktrees: Bool
    public var ignoredDirectoryNames: Set<String>

    public init(
        roots: [String],
        maximumDepth: Int,
        includeLinkedWorktrees: Bool,
        ignoredDirectoryNames: Set<String>
    ) {
        self.roots = roots
        self.maximumDepth = maximumDepth
        self.includeLinkedWorktrees = includeLinkedWorktrees
        self.ignoredDirectoryNames = ignoredDirectoryNames
    }
}

public enum RepositoryRefreshScope: Equatable, Sendable {
    /// Walk monitored roots and rebuild the repository list.
    case discovery
    /// Re-read git status for already-known repositories.
    ///
    /// A `nil` path set refreshes every known repository. A non-empty set refreshes
    /// only repositories whose worktree or git directory matches a path.
    case status(paths: Set<String>? = nil)

    public var isDiscovery: Bool {
        if case .discovery = self { return true }
        return false
    }

    public func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.discovery, _), (_, .discovery):
            return .discovery
        case let (.status(left), .status(right)):
            if let left, let right {
                return .status(paths: left.union(right))
            }
            return .status(paths: nil)
        }
    }
}

public struct RepositoryRefreshRequest: Equatable, Sendable {
    public var configuration: ScanConfiguration
    public var scope: RepositoryRefreshScope
    public var knownRepositories: [Repository]

    public init(
        configuration: ScanConfiguration,
        scope: RepositoryRefreshScope,
        knownRepositories: [Repository] = []
    ) {
        self.configuration = configuration
        self.scope = scope
        self.knownRepositories = knownRepositories
    }

    /// Discovery always wins over status so a root or depth change is not satisfied
    /// by a status-only follow-up. When a discovery is already queued, its settings
    /// are kept if the incoming request is only a status refresh.
    public func coalescing(_ next: Self) -> Self {
        let configuration: ScanConfiguration
        if next.scope.isDiscovery {
            configuration = next.configuration
        } else if scope.isDiscovery {
            configuration = self.configuration
        } else {
            configuration = next.configuration
        }
        return RepositoryRefreshRequest(
            configuration: configuration,
            scope: scope.merging(next.scope),
            knownRepositories: next.knownRepositories
        )
    }

    /// A discovery already in flight includes current git status for this configuration.
    ///
    /// A status run never covers another request: it may be stale relative to a newer
    /// status snapshot, and it cannot discover checkouts a later discovery needs.
    public func covers(_ next: Self) -> Bool {
        configuration == next.configuration && scope.isDiscovery && !next.scope.isDiscovery
    }
}

public struct RepositoryRefreshOutcome: Equatable, Sendable {
    public var repositories: [Repository]
    public var scope: RepositoryRefreshScope

    public init(repositories: [Repository], scope: RepositoryRefreshScope) {
        self.repositories = repositories
        self.scope = scope
    }
}
