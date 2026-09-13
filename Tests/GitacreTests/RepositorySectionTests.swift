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

    func testEveryAttentionCategoryHasExactlyOnePendingSection() {
        let repositories = [
            makeRepository(id: "clean"),
            makeRepository(id: "stash", stashCount: 1),
            makeRepository(id: "behind", worktree: makeWorktree(behind: 1)),
            makeRepository(id: "ahead", worktree: makeWorktree(ahead: 1)),
            makeRepository(id: "dirty", worktree: makeWorktree(changedFiles: 1)),
            makeRepository(id: "partial", worktree: cleanWorktree, scanFailure: "linked worktree failed"),
            makeRepository(id: "unreadable", worktree: nil, scanFailure: "git failed")
        ]

        let sections = repositorySections(repositories: repositories, showsPendingOnly: true)

        XCTAssertEqual(
            sections.map(\.title),
            ["SCAN ISSUES", "UNCOMMITTED", "AHEAD OF REMOTE", "BEHIND REMOTE", "STASHED"]
        )
        XCTAssertEqual(sections[0].repositories.map(\.id), ["partial", "unreadable"])
        XCTAssertEqual(sections[1].repositories.map(\.id), ["dirty"])
        XCTAssertEqual(sections[2].repositories.map(\.id), ["ahead"])
        XCTAssertEqual(sections[3].repositories.map(\.id), ["behind"])
        XCTAssertEqual(sections[4].repositories.map(\.id), ["stash"])

        let visibleIDs = sections.flatMap(\.repositories).map(\.id)
        XCTAssertEqual(Set(visibleIDs).count, visibleIDs.count, "a repository must not appear twice")
        XCTAssertFalse(visibleIDs.contains("clean"))
        XCTAssertEqual(pendingRepositoryDisplayOrder(repositories).map(\.id), visibleIDs)
    }

    private var cleanWorktree: Worktree {
        makeWorktree()
    }

    private func makeWorktree(
        changedFiles: Int = 0,
        ahead: Int = 0,
        behind: Int = 0
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
            operation: nil,
            lastCommitDate: nil
        )
    }

    private func makeRepository(
        id: String,
        worktree: Worktree? = nil,
        stashCount: Int = 0,
        scanFailure: String? = nil
    ) -> Repository {
        Repository(
            id: id,
            name: id,
            commonDirectory: "/tmp/\(id)/.git",
            remoteURL: nil,
            worktrees: worktree.map { [$0] } ?? (scanFailure == nil ? [cleanWorktree] : []),
            stashCount: stashCount,
            scanFailure: scanFailure
        )
    }
}
