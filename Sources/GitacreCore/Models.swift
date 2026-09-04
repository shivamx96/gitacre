import Foundation

public struct Repository: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let commonDirectory: String
    public let remoteURL: URL?
    public let worktrees: [Worktree]
    public let stashCount: Int
    public let iconPath: String?

    public init(
        id: String,
        name: String,
        commonDirectory: String,
        remoteURL: URL?,
        worktrees: [Worktree],
        stashCount: Int,
        iconPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.commonDirectory = commonDirectory
        self.remoteURL = remoteURL
        self.worktrees = worktrees
        self.stashCount = stashCount
        self.iconPath = iconPath
    }

    public var pendingWorktreeCount: Int {
        worktrees.filter(\.hasPendingWork).count
    }

    public var hasPendingWork: Bool {
        pendingWorktreeCount > 0 || stashCount > 0
    }

    public var totalChangedFiles: Int {
        worktrees.reduce(0) { $0 + $1.changedFiles }
    }

    public var totalAhead: Int {
        worktrees.reduce(0) { $0 + $1.ahead }
    }

    public var totalBehind: Int {
        worktrees.reduce(0) { $0 + $1.behind }
    }

    public var hasUncommittedWork: Bool {
        worktrees.contains { $0.changedFiles > 0 || $0.operation != nil }
    }
}

public struct Worktree: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let branch: String
    public let head: String
    public let isDetached: Bool
    public let isPrimary: Bool
    public let isLocked: Bool
    public let staged: Int
    public let unstaged: Int
    public let untracked: Int
    public let conflicted: Int
    public let changedFiles: Int
    public let ahead: Int
    public let behind: Int
    public let upstream: String?
    public let operation: GitOperation?
    public let lastCommitDate: Date?

    public init(
        id: String,
        path: String,
        branch: String,
        head: String,
        isDetached: Bool,
        isPrimary: Bool,
        isLocked: Bool,
        staged: Int,
        unstaged: Int,
        untracked: Int,
        conflicted: Int,
        changedFiles: Int,
        ahead: Int,
        behind: Int,
        upstream: String?,
        operation: GitOperation?,
        lastCommitDate: Date?
    ) {
        self.id = id
        self.path = path
        self.branch = branch
        self.head = head
        self.isDetached = isDetached
        self.isPrimary = isPrimary
        self.isLocked = isLocked
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.changedFiles = changedFiles
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
        self.operation = operation
        self.lastCommitDate = lastCommitDate
    }

    public var isDiverged: Bool {
        ahead > 0 && behind > 0
    }

    public var hasPendingWork: Bool {
        changedFiles > 0 || ahead > 0 || operation != nil
    }
}

public enum GitOperation: String, Equatable, Sendable {
    case merge
    case rebase
    case cherryPick = "cherry-pick"
    case revert
    case bisect

    public var displayName: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .bisect: "Bisect"
        }
    }
}

public enum GitHubAuthentication: Equatable, Sendable {
    case cliMissing
    case signedOut(executable: String)
    case signedIn(executable: String, login: String)
    case unavailable(executable: String, message: String)

    public var executable: String? {
        switch self {
        case .cliMissing:
            nil
        case let .signedOut(executable),
             let .signedIn(executable, _),
             let .unavailable(executable, _):
            executable
        }
    }

    public var login: String? {
        guard case let .signedIn(_, login) = self else { return nil }
        return login
    }

    public var isSignedIn: Bool {
        login != nil
    }
}

public struct PullRequest: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Equatable, Codable, Sendable {
        case reviewRequested
        case authored
    }

    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let repository: String
    public let author: String
    public let isDraft: Bool
    public let updatedAt: Date
    public let comments: Int
    public let kind: Kind

    public init(
        id: String,
        number: Int,
        title: String,
        url: URL,
        repository: String,
        author: String,
        isDraft: Bool,
        updatedAt: Date,
        comments: Int,
        kind: Kind
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repository = repository
        self.author = author
        self.isDraft = isDraft
        self.updatedAt = updatedAt
        self.comments = comments
        self.kind = kind
    }
}

public struct GitHubSnapshot: Equatable, Sendable {
    public let authentication: GitHubAuthentication
    public let pullRequests: [PullRequest]
    public let fetchedAt: Date?
    public let errorMessage: String?

    public init(
        authentication: GitHubAuthentication,
        pullRequests: [PullRequest] = [],
        fetchedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.authentication = authentication
        self.pullRequests = pullRequests
        self.fetchedAt = fetchedAt
        self.errorMessage = errorMessage
    }
}
