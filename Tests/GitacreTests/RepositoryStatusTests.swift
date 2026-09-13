import XCTest
@testable import Gitacre
import GitacreCore

final class RepositoryStatusTests: XCTestCase {
    func testRepositoryStatusAggregatesEveryWorktree() {
        let repository = Repository(
            id: "/tmp/example/.git",
            name: "example",
            commonDirectory: "/tmp/example/.git",
            remoteURL: nil,
            worktrees: [
                makeWorktree(id: "primary", isPrimary: true),
                makeWorktree(id: "feature", unstaged: 2, ahead: 1)
            ],
            stashCount: 0
        )

        XCTAssertEqual(
            repositoryStatusFacts(repository).map(\.text),
            ["2 modified", "1 ahead"]
        )
        XCTAssertEqual(repositoryStatusText(repository: repository), "2 modified · 1 ahead")
    }

    func testCleanStatusDoesNotClaimRemoteFreshness() {
        let tracking = makeWorktree(id: "tracking", isPrimary: true)
        let untrackedBranch = makeWorktree(id: "local", isPrimary: true, upstream: nil)

        XCTAssertEqual(statusFacts(repository: nil, worktree: tracking).map(\.text), ["clean"])
        XCTAssertEqual(
            statusFacts(repository: nil, worktree: untrackedBranch).map(\.text),
            ["clean", "no upstream"]
        )
    }

    private func makeWorktree(
        id: String,
        isPrimary: Bool = false,
        unstaged: Int = 0,
        ahead: Int = 0,
        upstream: String? = "origin/main"
    ) -> Worktree {
        Worktree(
            id: id,
            path: "/tmp/\(id)",
            branch: id == "primary" ? "main" : id,
            head: "abcdef12",
            isDetached: false,
            isPrimary: isPrimary,
            isLocked: false,
            staged: 0,
            unstaged: unstaged,
            untracked: 0,
            conflicted: 0,
            changedFiles: unstaged,
            ahead: ahead,
            behind: 0,
            upstream: upstream,
            operation: nil,
            lastCommitDate: nil
        )
    }
}
