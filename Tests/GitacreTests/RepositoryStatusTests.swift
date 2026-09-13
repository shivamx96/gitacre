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

    private func makeWorktree(
        id: String,
        isPrimary: Bool = false,
        unstaged: Int = 0,
        ahead: Int = 0
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
            upstream: "origin/main",
            operation: nil,
            lastCommitDate: nil
        )
    }
}
