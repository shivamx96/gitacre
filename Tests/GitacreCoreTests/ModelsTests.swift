import XCTest
@testable import GitacreCore

final class ModelsTests: XCTestCase {
    func testBehindOnlyWorktreeNeedsAttention() {
        let worktree = makeWorktree(behind: 2)
        let repository = Repository(
            id: "/tmp/example/.git",
            name: "example",
            commonDirectory: "/tmp/example/.git",
            remoteURL: nil,
            worktrees: [worktree],
            stashCount: 0
        )

        XCTAssertTrue(worktree.hasPendingWork)
        XCTAssertEqual(repository.pendingWorktreeCount, 1)
        XCTAssertTrue(repository.hasPendingWork)
        XCTAssertTrue(repository.needsAttention)
    }

    private func makeWorktree(
        changedFiles: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        operation: GitOperation? = nil
    ) -> Worktree {
        Worktree(
            id: "/tmp/example",
            path: "/tmp/example",
            branch: "main",
            head: "abcdef12",
            isDetached: false,
            isPrimary: true,
            isLocked: false,
            staged: 0,
            unstaged: 0,
            untracked: 0,
            conflicted: 0,
            changedFiles: changedFiles,
            ahead: ahead,
            behind: behind,
            upstream: "origin/main",
            operation: operation,
            lastCommitDate: nil
        )
    }
}
