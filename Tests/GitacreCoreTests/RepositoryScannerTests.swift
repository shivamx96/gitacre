import XCTest
@testable import GitacreCore

final class RepositoryScannerTests: XCTestCase {
    func testGroupsLinkedWorktreesUnderOneRepository() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let primary = temporaryDirectory.appendingPathComponent("example", isDirectory: true)
        let linked = temporaryDirectory.appendingPathComponent("example-feature", isDirectory: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = ProcessRunner()
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", primary.path, "init", "-q"]).succeeded)
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", primary.path, "config", "user.email", "test@example.com"]).succeeded)
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", primary.path, "config", "user.name", "Test User"]).succeeded)
        try Data("initial\n".utf8).write(to: primary.appendingPathComponent("README.md"))
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", primary.path, "add", "README.md"]).succeeded)
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", primary.path, "commit", "-qm", "Initial"]).succeeded)
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", primary.path, "branch", "feature/menu"]).succeeded)
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", primary.path, "worktree", "add", "-q", linked.path, "feature/menu"]).succeeded)
        try Data("pending\n".utf8).write(to: linked.appendingPathComponent("pending.txt"))
        let publicDirectory = primary.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: publicDirectory.appendingPathComponent("favicon.png"))
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", primary.path, "add", "public/favicon.png"]).succeeded)
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", primary.path, "commit", "-qm", "Add icon"]).succeeded)

        let repositories = RepositoryScanner().scan(roots: [temporaryDirectory.path])

        XCTAssertEqual(repositories.count, 1)
        XCTAssertEqual(repositories[0].worktrees.count, 2)
        XCTAssertEqual(repositories[0].pendingWorktreeCount, 1)
        XCTAssertEqual(repositories[0].iconPath, publicDirectory.appendingPathComponent("favicon.png").path)
        XCTAssertEqual(
            repositories[0].worktrees.first(where: {
                URL(fileURLWithPath: $0.path).lastPathComponent == linked.lastPathComponent
            })?.untracked,
            1
        )

        let primaryOnly = RepositoryScanner(includeLinkedWorktrees: false).scan(roots: [temporaryDirectory.path])
        XCTAssertEqual(primaryOnly.count, 1)
        XCTAssertEqual(primaryOnly[0].worktrees.count, 1)
    }

    func testRepositoryWithOnlyAStashIsPending() {
        let repository = Repository(
            id: "/tmp/example/.git",
            name: "example",
            commonDirectory: "/tmp/example/.git",
            remoteURL: nil,
            worktrees: [],
            stashCount: 1
        )

        XCTAssertTrue(repository.hasPendingWork)
        XCTAssertEqual(repository.pendingWorktreeCount, 0)
    }

    func testProjectIconDiscoveryPrefersConventionalLocationAndSkipsDependencies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let publicDirectory = root.appendingPathComponent("public", isDirectory: true)
        let dependencyDirectory = root.appendingPathComponent("node_modules/package", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependencyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("dependency".utf8).write(to: dependencyDirectory.appendingPathComponent("favicon.ico"))
        let expected = publicDirectory.appendingPathComponent("favicon.svg")
        try Data("<svg/>".utf8).write(to: expected)

        XCTAssertEqual(RepositoryScanner.projectIconPath(in: root.path), expected.path)
    }

    func testParsesWorktreePorcelainOutput() {
        let output = """
        worktree /Users/test/Projects/example\0HEAD abcdef123456\0branch refs/heads/main\0\0worktree /Users/test/Worktrees/feature\0HEAD 987654321abc\0branch refs/heads/feature/menu\0locked reason\0\0
        """

        let records = RepositoryScanner.parseWorktreeList(output)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].path, "/Users/test/Projects/example")
        XCTAssertEqual(records[0].head, "abcdef123456")
        XCTAssertEqual(records[0].branchReference, "refs/heads/main")
        XCTAssertFalse(records[0].isLocked)
        XCTAssertEqual(records[1].path, "/Users/test/Worktrees/feature")
        XCTAssertTrue(records[1].isLocked)
    }

    func testParsesStatusWithoutDoubleCountingFiles() {
        let output = """
        # branch.oid abcdef
        # branch.head feature/menu
        # branch.upstream origin/feature/menu
        # branch.ab +2 -1
        1 M. N... 100644 100644 100644 abc abc file-a.swift
        1 .M N... 100644 100644 100644 abc abc file-b.swift
        1 MM N... 100644 100644 100644 abc abc file-c.swift
        ? new-file.swift
        u UU N... 100644 100644 100644 100644 abc abc abc conflict.swift
        """

        let status = RepositoryScanner.parseStatus(output)

        XCTAssertEqual(status.branch, "feature/menu")
        XCTAssertEqual(status.upstream, "origin/feature/menu")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.staged, 2)
        XCTAssertEqual(status.unstaged, 2)
        XCTAssertEqual(status.untracked, 1)
        XCTAssertEqual(status.conflicted, 1)
        XCTAssertEqual(status.changedFiles, 5)
    }

    func testNormalizesCommonOriginFormats() {
        XCTAssertEqual(
            RepositoryScanner.webURL(forOrigin: "git@github.com:owner/example.git")?.absoluteString,
            "https://github.com/owner/example"
        )
        XCTAssertEqual(
            RepositoryScanner.webURL(forOrigin: "ssh://git@gitlab.com/owner/example.git")?.absoluteString,
            "https://gitlab.com/owner/example"
        )
        XCTAssertEqual(
            RepositoryScanner.webURL(forOrigin: "https://bitbucket.org/owner/example.git")?.absoluteString,
            "https://bitbucket.org/owner/example"
        )
    }
}
