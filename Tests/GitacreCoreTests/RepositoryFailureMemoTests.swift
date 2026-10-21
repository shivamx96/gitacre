import XCTest
@testable import GitacreCore

final class RepositoryFailureMemoTests: XCTestCase {
    func testNegativeResultsAreReusedButFirstCommitIsVisibleAndDiscoveryRechecksOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CountingRunner()
        func git(_ args: [String]) {
            XCTAssertTrue(ProcessRunner().run(executable: "/usr/bin/git", arguments: ["-C", root.path] + args).succeeded)
        }
        git(["init", "-q"])
        let scanner = RepositoryScanner(runner: runner)
        let initial = scanner.scan(roots: [root.path])
        XCTAssertEqual(runner.count("config"), 1)
        XCTAssertEqual(runner.count("log"), 1)
        let empty = scanner.refreshStatus(of: initial)
        XCTAssertEqual(runner.count("config"), 1)
        XCTAssertEqual(runner.count("log"), 1)
        XCTAssertNil(empty.first?.worktrees.first?.lastCommitDate)
        git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm", "first"])
        let committed = scanner.refreshStatus(of: empty)
        XCTAssertNotNil(committed.first?.worktrees.first?.lastCommitDate)
        XCTAssertEqual(runner.count("log"), 2)
        git(["remote", "add", "origin", "https://github.com/example/repo.git"])
        XCTAssertNil(scanner.refreshStatus(of: committed).first?.remoteURL)
        XCTAssertEqual(runner.count("config"), 1)
        XCTAssertNotNil(scanner.scan(roots: [root.path]).first?.remoteURL)
        XCTAssertEqual(runner.count("config"), 2)
    }

    func testWorkerRetainsMemoBetweenRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(ProcessRunner().run(executable: "/usr/bin/git", arguments: ["-C", root.path, "init", "-q"]).succeeded)
        let worker = RepositoryRefreshWorker()
        let configuration = ScanConfiguration(roots: [root.path], maximumDepth: 3, includeLinkedWorktrees: true, ignoredDirectoryNames: [])
        for (scope, expected) in [(RepositoryRefreshScope.discovery, 6), (.status(), 3), (.status(), 3), (.discovery, 6)] {
            let context = PerformanceDiagnostics.shared.context(trigger: .manual)
            _ = await worker.run(RepositoryRefreshRequest(configuration: configuration, scope: scope, diagnostics: context))
            let completed = PerformanceDiagnostics.shared.snapshot().events.last { $0.kind == .completed && $0.requestID == context.id }
            XCTAssertEqual(completed?.commandCount, expected)
        }
    }

    func testMemoSeparatesRepositoriesAndWorktreesAndResets() {
        let memo = RepositoryFailureMemo()
        memo.rememberMissingOrigin("a")
        XCTAssertTrue(memo.originIsAbsent("a"))
        XCTAssertFalse(memo.originIsAbsent("b"))
        memo.rememberUnbornHead("a", checkout: "one")
        XCTAssertTrue(memo.skipsLog("a", checkout: "one", unborn: true))
        XCTAssertFalse(memo.skipsLog("a", checkout: "two", unborn: true))
        XCTAssertFalse(memo.skipsLog("a", checkout: "one", unborn: false))
        memo.reset()
        XCTAssertFalse(memo.originIsAbsent("a"))
        XCTAssertFalse(memo.skipsLog("a", checkout: "one", unborn: true))
    }
}

private final class CountingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String: Int] = [:]
    func run(executable: String, arguments: [String]) -> ProcessResult {
        lock.lock(); commands[arguments[2], default: 0] += 1; lock.unlock()
        return ProcessRunner().run(executable: executable, arguments: arguments)
    }
    func count(_ command: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return commands[command, default: 0]
    }
}
