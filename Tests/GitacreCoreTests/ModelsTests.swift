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

    func testWorktreePendingStateMatrix() {
        let cases: [(name: String, worktree: Worktree, pending: Bool)] = [
            ("clean", makeWorktree(), false),
            ("locked", makeWorktree(isLocked: true), false),
            ("staged", makeWorktree(staged: 1, changedFiles: 1), true),
            ("modified", makeWorktree(unstaged: 1, changedFiles: 1), true),
            ("untracked", makeWorktree(untracked: 1, changedFiles: 1), true),
            ("conflicted", makeWorktree(conflicted: 1, changedFiles: 1), true),
            ("operation", makeWorktree(operation: .rebase), true),
            ("ahead", makeWorktree(ahead: 1), true),
            ("behind", makeWorktree(behind: 1), true),
            ("diverged", makeWorktree(ahead: 2, behind: 3), true)
        ]

        for testCase in cases {
            XCTAssertEqual(
                testCase.worktree.hasPendingWork,
                testCase.pending,
                "Unexpected pending state for \(testCase.name)"
            )
        }
    }

    func testRepositoryAttentionStateMatrix() {
        let clean = makeRepository(worktrees: [makeWorktree()])
        let stashed = makeRepository(worktrees: [makeWorktree()], stashCount: 1)
        let unreadable = makeRepository(worktrees: [], scanFailure: "git failed")
        let partlyUnreadable = makeRepository(
            worktrees: [makeWorktree()],
            scanFailure: "linked worktree failed"
        )

        XCTAssertFalse(clean.hasPendingWork)
        XCTAssertFalse(clean.needsAttention)
        XCTAssertTrue(stashed.hasPendingWork)
        XCTAssertTrue(stashed.needsAttention)
        XCTAssertFalse(unreadable.hasPendingWork)
        XCTAssertTrue(unreadable.needsAttention)
        XCTAssertFalse(partlyUnreadable.hasPendingWork)
        XCTAssertTrue(partlyUnreadable.needsAttention)
    }

    func testRepositoryIsAffectedByWorktreeAndGitDirectoryPaths() {
        let repository = makeRepository(worktrees: [
            makeWorktree(path: "/tmp/example")
        ])

        XCTAssertTrue(repository.isAffected(byChangedPath: "/tmp/example"))
        XCTAssertTrue(repository.isAffected(byChangedPath: "/tmp/example/src/file.swift"))
        XCTAssertTrue(repository.isAffected(byChangedPath: "/tmp/example/.git/HEAD"))
        XCTAssertFalse(repository.isAffected(byChangedPath: "/tmp/example-other/file.swift"))
        XCTAssertFalse(repository.isAffected(byChangedPath: "/tmp/elsewhere"))
    }

    private func makeWorktree(
        path: String = "/tmp/example",
        isLocked: Bool = false,
        staged: Int = 0,
        unstaged: Int = 0,
        untracked: Int = 0,
        conflicted: Int = 0,
        changedFiles: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        operation: GitOperation? = nil
    ) -> Worktree {
        Worktree(
            id: path,
            path: path,
            branch: "main",
            head: "abcdef12",
            isDetached: false,
            isPrimary: true,
            isLocked: isLocked,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked,
            conflicted: conflicted,
            changedFiles: changedFiles,
            ahead: ahead,
            behind: behind,
            upstream: "origin/main",
            operation: operation,
            lastCommitDate: nil
        )
    }

    private func makeRepository(
        worktrees: [Worktree],
        stashCount: Int = 0,
        scanFailure: String? = nil
    ) -> Repository {
        Repository(
            id: "/tmp/example/.git",
            name: "example",
            commonDirectory: "/tmp/example/.git",
            remoteURL: nil,
            worktrees: worktrees,
            stashCount: stashCount,
            scanFailure: scanFailure
        )
    }
}
