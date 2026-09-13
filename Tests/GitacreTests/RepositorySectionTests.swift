import XCTest
@testable import Gitacre
import GitacreCore

final class RepositorySectionTests: XCTestCase {
    func testPartlyUnreadableRepositoryIsVisibleAndKeyboardSelectable() throws {
        let repository = Repository(
            id: "/tmp/example/.git",
            name: "example",
            commonDirectory: "/tmp/example/.git",
            remoteURL: nil,
            worktrees: [cleanWorktree],
            stashCount: 0,
            scanFailure: "A linked worktree could not be read."
        )

        XCTAssertTrue(repository.isReadable)
        XCTAssertTrue(repository.needsAttention)

        let section = try XCTUnwrap(
            repositorySections(repositories: [repository], showsPendingOnly: true).first
        )
        XCTAssertEqual(section.title, "SCAN ISSUES")
        XCTAssertEqual(section.repositories.map(\.id), [repository.id])
        XCTAssertEqual(pendingRepositoryDisplayOrder([repository]).map(\.id), [repository.id])
    }

    private var cleanWorktree: Worktree {
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
            changedFiles: 0,
            ahead: 0,
            behind: 0,
            upstream: "origin/main",
            operation: nil,
            lastCommitDate: nil
        )
    }
}
