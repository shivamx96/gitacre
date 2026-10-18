import Foundation

public struct ScanConfiguration: Equatable, Codable, Sendable {
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

    /// A later request may describe changes made after the active scan read a file.
    /// Always queue a follow-up, even for identical discovery configurations.
    public func covers(_ next: Self) -> Bool { false }
}

public struct RepositoryRefreshOutcome: Equatable, Sendable {
    public var repositories: [Repository]
    public var scope: RepositoryRefreshScope
    public init(repositories: [Repository], scope: RepositoryRefreshScope) {
        self.repositories = repositories
        self.scope = scope
    }
}

public struct LocalSnapshot: Codable, Sendable {
    public let configuration: ScanConfiguration
    public let repositories: [Repository]
    public let fetchedAt: Date

    public init(configuration: ScanConfiguration, repositories: [Repository], fetchedAt: Date) {
        self.configuration = configuration
        self.repositories = repositories
        self.fetchedAt = fetchedAt
    }

    public static func read(at url: URL, configuration: ScanConfiguration) -> Self? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.configuration == configuration else { return nil }
        return value
    }

    public func write(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Keeps the latest scan baseline inside the serialized worker, even before the UI
/// resumes its continuation. Targeted refreshes cannot restore an older unrelated row.
public actor RepositoryRefreshWorker {
    private var configuration: ScanConfiguration?
    private var repositories: [Repository] = []
    public init() {}
    public func run(_ request: RepositoryRefreshRequest) async -> RepositoryRefreshOutcome {
        var effective = request
        if configuration == request.configuration {
            effective.knownRepositories = repositories
        } else if !request.scope.isDiscovery {
            effective.scope = .discovery
        }
        let input = effective
        let result = await Task.detached(priority: .utility) { RepositoryScanner.run(input) }.value
        configuration = request.configuration
        repositories = result
        return RepositoryRefreshOutcome(repositories: result, scope: effective.scope)
    }
}
