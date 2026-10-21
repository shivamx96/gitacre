import XCTest
@testable import GitacreCore

final class BackgroundRefreshPolicyTests: XCTestCase {
    private let repository = Repository(id: "repo", name: "repo", commonDirectory: "/root/repo/.git",
        remoteURL: nil, worktrees: [], stashCount: 0)

    func testVisibleGitChangesPassFilterAndSelectStatus() {
        for relative in ["HEAD", "index", "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
                         "BISECT_LOG", "rebase-merge", "rebase-merge/done", "rebase-apply/next", "refs/heads/main",
                         "refs/stash", "packed-refs", "logs/refs/stash", "worktrees/linked/HEAD", "worktrees/linked/index"] {
            let path = "/root/repo/.git/" + relative
            let batch = BackgroundRefreshPolicy.batch(paths: [path], rescan: false, repositories: [repository])
            XCTAssertEqual(batch.statusScope, .status(paths: [path]), relative)
            XCTAssertFalse(batch.needsDiscovery, relative)
            XCTAssertEqual(batch.ignored, 0)
        }
    }

    func testNoiseAndLocksAreIgnoredIncludingLinkedWorktreeLocks() {
        for relative in ["index.lock", "refs/heads/main.lock", "worktrees/linked/index.lock", "objects/ab/cd", "logs/HEAD", "config", "FETCH_HEAD"] {
            let batch = BackgroundRefreshPolicy.batch(paths: ["/root/repo/.git/" + relative], rescan: false, repositories: [repository])
            XCTAssertNil(batch.statusScope, relative)
            XCTAssertFalse(batch.needsDiscovery, relative)
            XCTAssertEqual(batch.ignored, 1)
        }
        XCTAssertTrue(BackgroundRefreshPolicy.accepts(path: "/root/repo/package.lock"))
        XCTAssertFalse(BackgroundRefreshPolicy.accepts(path: "/external/gitdir/objects/ab", commonDirectories: ["/external/gitdir"]))
        XCTAssertTrue(BackgroundRefreshPolicy.accepts(path: "/external/gitdir/HEAD", commonDirectories: ["/external/gitdir"]))
    }

    func testEditCommitBranchStashRebaseAndCloneScopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let checkout = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(ProcessRunner().run(executable: "/usr/bin/git", arguments: ["-C", checkout.path, "init", "-q"]).succeeded)
        let repos = RepositoryScanner().scan(roots: [root.path])
        for relative in ["file.swift", ".git/refs/heads/main", ".git/HEAD", ".git/refs/stash", ".git/rebase-merge/done"] {
            let path = checkout.appendingPathComponent(relative).path
            let batch = BackgroundRefreshPolicy.batch(paths: [path], rescan: false, repositories: repos)
            XCTAssertEqual(batch.statusScope, .status(paths: [path]), relative)
            XCTAssertFalse(batch.needsDiscovery, "path=\(path) repos=\(repos)")
        }
        for path in [root.appendingPathComponent("new-clone/.git").path, root.path] {
            XCTAssertTrue(BackgroundRefreshPolicy.batch(paths: [path], rescan: false, repositories: repos).needsDiscovery)
        }
    }

    func testRescanBypassesFilteringAndMixedBatchKeepsImmediateStatus() {
        let rescan = BackgroundRefreshPolicy.batch(paths: ["/root/repo/.git/index.lock"], rescan: true, repositories: [repository])
        XCTAssertEqual(rescan.statusScope, .status())
        XCTAssertTrue(rescan.needsDiscovery)
        let mixed = BackgroundRefreshPolicy.batch(paths: ["/root/new/.git", "/root/repo/.git/HEAD", "/root/repo/.git/index.lock"], rescan: false, repositories: [repository])
        XCTAssertEqual(mixed.statusScope, .status(paths: ["/root/repo/.git/HEAD"]))
        XCTAssertTrue(mixed.needsDiscovery)
        XCTAssertEqual(mixed.ignored, 1)
    }

    func testDiscoveryHasBoundedTrailingDeadlineWithoutStarvation() {
        var debounce = DiscoveryDebounce()
        debounce.didStartDiscovery(at: 0) // startup bypasses delay
        XCTAssertEqual(debounce.request(at: 1), 60)
        XCTAssertEqual(debounce.request(at: 59), 60)
        debounce.didStartDiscovery(at: 60)
        XCTAssertEqual(debounce.request(at: 61), 120)
        debounce.didStartDiscovery(at: 70) // manual refresh satisfies prior invalidations
        XCTAssertEqual(debounce.request(at: 71), 130)
        debounce.didStartDiscovery(at: 130)
        XCTAssertEqual(debounce.request(at: 200), 201)
    }

    func testPanelFreshnessBoundaryStaleAndMissingSuccess() {
        let now = Date(timeIntervalSince1970: 1000)
        for age in [30.0, 120.0] {
            XCTAssertFalse(BackgroundRefreshPolicy.needsPanelRefresh(lastSuccess: now.addingTimeInterval(-age + 1), now: now, maximumAge: age))
            XCTAssertTrue(BackgroundRefreshPolicy.needsPanelRefresh(lastSuccess: now.addingTimeInterval(-age), now: now, maximumAge: age))
            XCTAssertTrue(BackgroundRefreshPolicy.needsPanelRefresh(lastSuccess: nil, now: now, maximumAge: age))
            XCTAssertTrue(BackgroundRefreshPolicy.needsPanelRefresh(lastSuccess: now, now: now, maximumAge: age, stale: true))
        }
    }
}
