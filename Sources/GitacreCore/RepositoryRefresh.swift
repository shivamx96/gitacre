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
    public var diagnostics: DiagnosticContext?
    public var knownRepositories: [Repository]

    public init(
        configuration: ScanConfiguration,
        scope: RepositoryRefreshScope,
        knownRepositories: [Repository] = [],
        diagnostics: DiagnosticContext? = nil
    ) {
        self.diagnostics = diagnostics
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
            knownRepositories: next.knownRepositories,
            diagnostics: diagnostics ?? next.diagnostics
        )
    }

    /// A later request may describe changes made after the active scan read a file.
    /// Always queue a follow-up, even for identical discovery configurations.
    public func covers(_ next: Self) -> Bool { false }
}

/// A filesystem discovery failure is separate from a repository Git-status failure:
/// the inaccessible folder may contain repositories we have never discovered.
public struct RepositoryDiscoveryIssue: Identifiable, Equatable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct RepositoryScanResult: Sendable {
    public let repositories: [Repository]
    public let discoveryIssues: [RepositoryDiscoveryIssue]

    public init(repositories: [Repository], discoveryIssues: [RepositoryDiscoveryIssue] = []) {
        self.repositories = repositories
        self.discoveryIssues = discoveryIssues
    }
}

public struct RepositoryRefreshOutcome: Equatable, Sendable {
    public var diagnostics: DiagnosticContext?
    public var repositories: [Repository]
    public var discoveryIssues: [RepositoryDiscoveryIssue]
    public var scope: RepositoryRefreshScope
    public init(repositories: [Repository], scope: RepositoryRefreshScope, diagnostics: DiagnosticContext? = nil, discoveryIssues: [RepositoryDiscoveryIssue] = []) {
        self.discoveryIssues = discoveryIssues
        self.diagnostics = diagnostics
        self.repositories = repositories
        self.scope = scope
    }
}

public struct LocalSnapshot: Codable, Sendable {
    public let configuration: ScanConfiguration
    public let repositories: [Repository]
    public let fetchedAt: Date
    // Optional for snapshots written before discovery issues were persisted.
    public let discoveryIssues: [RepositoryDiscoveryIssue]?

    public init(configuration: ScanConfiguration, repositories: [Repository], fetchedAt: Date, discoveryIssues: [RepositoryDiscoveryIssue] = []) {
        self.discoveryIssues = discoveryIssues
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
    private let failureMemo = RepositoryFailureMemo()
    private var configuration: ScanConfiguration?
    private var repositories: [Repository] = []
    private var discoveryIssues: [RepositoryDiscoveryIssue] = []
    public init() {}
    public func run(_ request: RepositoryRefreshRequest) async -> RepositoryRefreshOutcome {
        var effective = request
        if configuration == request.configuration {
            effective.knownRepositories = repositories
        } else if !request.scope.isDiscovery {
            effective.scope = .discovery
        }
        let failureMemo = self.failureMemo
        let input = effective
        let started = ProcessInfo.processInfo.systemUptime
        let counter = DiagnosticCommandCounter()
        let result = await Task.detached(priority: .utility) {
            DiagnosticContext.$current.withValue(input.diagnostics) {
                DiagnosticCommandCounter.$current.withValue(counter) { RepositoryScanner.runWithIssues(input, failureMemo: failureMemo) }
            }
        }.value
        if effective.scope.isDiscovery { discoveryIssues = result.discoveryIssues }
        PerformanceDiagnostics.shared.record(DiagnosticEvent(.completed, context: input.diagnostics,
            duration: ProcessInfo.processInfo.systemUptime - started, discovery: input.scope.isDiscovery,
            count: result.repositories.count, worktrees: result.repositories.reduce(0) { $0 + $1.worktrees.count },
            failed: !discoveryIssues.isEmpty || result.repositories.contains { $0.scanFailure != nil }, commandCount: counter.count))
        configuration = request.configuration
        repositories = result.repositories
        return RepositoryRefreshOutcome(repositories: result.repositories, scope: effective.scope, diagnostics: effective.diagnostics, discoveryIssues: discoveryIssues)
    }
}
