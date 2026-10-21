import Foundation
import XCTest
@testable import GitacreCore

final class PerformanceDiagnosticsTests: XCTestCase {
    func testRingEvictsInOrderAndPreservesSessionTotals() throws {
        let recorder = PerformanceDiagnostics(capacity: 3)
        for _ in 0..<10 {
            recorder.record(DiagnosticEvent(.command, command: .status, duration: 0.02, failed: true))
        }
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.events.map(\.sequence), [8, 9, 10])
        XCTAssertEqual(snapshot.overwritten, 7)
        let aggregate = try XCTUnwrap(snapshot.aggregates["command.none.status"])
        XCTAssertEqual(aggregate.events, 10)
        XCTAssertEqual(aggregate.failures, 10)
        XCTAssertEqual(aggregate.durationBuckets, [0, 10, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(aggregate.totalDuration, 0.2, accuracy: 0.00001)
        XCTAssertNoThrow(try JSONDecoder().decode(JSONValue.self, from: recorder.exportJSON()))
    }

    func testConcurrentRecordingHasUniqueSequencesAndBoundedStorage() {
        let recorder = PerformanceDiagnostics(capacity: 100)
        DispatchQueue.concurrentPerform(iterations: 5_000) { _ in
            let context = recorder.context(trigger: .filesystem)
            recorder.record(DiagnosticEvent(.requested, context: context))
        }
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.events.count, 100)
        XCTAssertEqual(snapshot.events.map(\.sequence), Array(UInt64(4901)...5000))
        XCTAssertEqual(Set(snapshot.events.compactMap(\.requestID)).count, 100)
        XCTAssertEqual(snapshot.aggregates["requested.filesystem.none"]?.events, 5000)
        XCTAssertEqual(snapshot.overwritten, 4900)
    }

    func testContextSurvivesDispatchAndCoalescing() {
        let context = PerformanceDiagnostics().context(trigger: .filesystem)
        DiagnosticContext.$current.withValue(context) {
            let ids = RepositoryScanner.concurrentMap(Array(0..<20)) { _ in DiagnosticContext.current?.id }
            XCTAssertTrue(ids.allSatisfy { $0 == context.id })
        }
        let config = ScanConfiguration(roots: [], maximumDepth: 3, includeLinkedWorktrees: true, ignoredDirectoryNames: [])
        let first = RepositoryRefreshRequest(configuration: config, scope: .status(), diagnostics: context)
        let second = RepositoryRefreshRequest(configuration: config, scope: .discovery,
            diagnostics: PerformanceDiagnostics.shared.context(trigger: .manual))
        XCTAssertEqual(first.coalescing(second).diagnostics, context)
        XCTAssertTrue(first.coalescing(second).scope.isDiscovery)
        XCTAssertNil(DiagnosticContext.current)
    }

    func testCommandClassificationDoesNotRetainSensitiveArguments() throws {
        let path = "/Users/private/secret-repository"
        let args = ["-C", path, "--no-optional-locks", "status", "--porcelain=v2"]
        let recorder = PerformanceDiagnostics()
        recorder.record(DiagnosticEvent(.command, command: .classify(executable: "/usr/bin/git", arguments: args)))
        let json = String(decoding: try recorder.exportJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains("status"))
        XCTAssertFalse(json.contains(path))
        XCTAssertFalse(json.contains("porcelain"))
        XCTAssertEqual(DiagnosticCommand.classify(executable: "/custom/gh", arguments: ["api", "secret"]), .github)
        XCTAssertEqual(DiagnosticCommand.classify(executable: "/bin/echo", arguments: ["status"]), .other)
    }

    func testInvalidDurationsCannotBreakExportAndCapacityIsClamped() throws {
        let recorder = PerformanceDiagnostics(capacity: 0)
        recorder.record(DiagnosticEvent(.completed, duration: .infinity))
        XCTAssertNil(recorder.snapshot().events.first?.duration)
        recorder.record(DiagnosticEvent(.completed, duration: -1))
        XCTAssertEqual(recorder.snapshot().events.first?.duration, 0)
        XCTAssertEqual(recorder.snapshot().capacity, 1)
        XCTAssertNoThrow(try recorder.exportJSON())
    }

    func testScanCountsAndCorrelatesCommandsAcrossRepositories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["first", "second"] {
            let result = ProcessRunner().run(executable: "/usr/bin/git", arguments: ["init", "--quiet", root.appendingPathComponent(name).path])
            XCTAssertTrue(result.succeeded)
        }
        let recorder = PerformanceDiagnostics.shared
        let context = recorder.context(trigger: .startup)
        let request = RepositoryRefreshRequest(configuration: ScanConfiguration(roots: [root.path],
            maximumDepth: 3, includeLinkedWorktrees: true, ignoredDirectoryNames: []),
            scope: .discovery, diagnostics: context)
        let outcome = await RepositoryRefreshWorker().run(request)
        XCTAssertEqual(outcome.repositories.count, 2)
        let events = recorder.snapshot().events.filter { $0.requestID == context.id }
        let commands = events.filter { $0.kind == .command }
        XCTAssertFalse(commands.isEmpty)
        XCTAssertEqual(events.last { $0.kind == .completed }?.commandCount, commands.count)
        XCTAssertEqual(Set(commands.compactMap(\.repository)).count, 2)
        XCTAssertTrue(commands.allSatisfy { $0.trigger == .startup })
        XCTAssertFalse(String(decoding: try recorder.exportJSON(), as: UTF8.self).contains(root.path))
    }

    func testRealCommandsCarryCorrelationAndFailureStatus() {
        let recorder = PerformanceDiagnostics.shared
        let context = recorder.context(trigger: .manual)
        DiagnosticContext.$current.withValue(context) {
            _ = ProcessRunner().run(executable: "/usr/bin/false", arguments: [])
        }
        let event = recorder.snapshot().events.last { $0.requestID == context.id && $0.kind == .command }
        XCTAssertEqual(event?.failed, true)
        XCTAssertEqual(event?.exitStatus, 1)
        XCTAssertEqual(event?.trigger, .manual)
    }

    func testExportRoundTripsAndKeepsSessionTotalsAfterEviction() throws {
        let recorder = PerformanceDiagnostics(capacity: 2)
        let github = recorder.context(trigger: .githubTimer)
        recorder.record(DiagnosticEvent(.githubCompleted, context: github, duration: 0.3, count: 4, failed: true, commandCount: 3))
        recorder.record(DiagnosticEvent(.filesystem, context: recorder.context(trigger: .filesystem), count: 5,
            insideGitDirectory: 4, rescan: false, unmatched: 1))
        recorder.record(DiagnosticEvent(.published, context: recorder.context(trigger: .manual), duration: 1.2, count: 9, changed: false))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DiagnosticSnapshot.self, from: recorder.exportJSON())

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.events.count, 2, "timeline keeps only the newest entries")
        XCTAssertEqual(snapshot.overwritten, 1)
        XCTAssertEqual(snapshot.events.map(\.kind), [.filesystem, .published])
        XCTAssertEqual(Set(snapshot.aggregates.keys),
            ["githubCompleted.githubTimer.none", "filesystem.filesystem.none", "published.manual.none"])
        let evicted = try XCTUnwrap(snapshot.aggregates["githubCompleted.githubTimer.none"])
        XCTAssertEqual(evicted.totalCommands, 3)
        XCTAssertEqual(evicted.failures, 1)
        XCTAssertEqual(evicted.totalCount, 4)
        XCTAssertEqual(snapshot.aggregates["filesystem.filesystem.none"]?.totalInsideGitDirectory, 4)
        XCTAssertEqual(snapshot.aggregates["filesystem.filesystem.none"]?.totalUnmatched, 1)
        XCTAssertEqual(snapshot.aggregates["published.manual.none"]?.unchanged, 1)
        XCTAssertGreaterThan(snapshot.processors, 0)
        XCTAssertGreaterThanOrEqual(snapshot.scanConcurrency, 4)
        XCTAssertGreaterThanOrEqual(snapshot.cpu.selfUser + snapshot.cpu.selfSystem, 0)
        XCTAssertGreaterThanOrEqual(snapshot.cpu.childrenUser, 0)
        XCTAssertGreaterThan(snapshot.elapsed, 0)
    }

    func testEventShapeHasNoFreeFormFields() {
        let event = DiagnosticEvent(.command, context: DiagnosticContext(id: 1, trigger: .manual, since: 0), command: .status)
        for child in Mirror(reflecting: event).children {
            let type = String(describing: Swift.type(of: child.value))
            for forbidden in ["String", "URL", "Array", "Dictionary", "Set<", "Data"] {
                XCTAssertFalse(type.contains(forbidden), "\(child.label ?? "?") is \(type); events must stay fixed-shape")
            }
        }
        XCTAssertEqual(event.repository, nil)
    }

    func testWorkerRecordsActualScopeWhenAStatusRequestIsUpgradedToDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(ProcessRunner().run(executable: "/usr/bin/git", arguments: ["init", "--quiet", root.appendingPathComponent("only").path]).succeeded)
        let recorder = PerformanceDiagnostics.shared
        let context = recorder.context(trigger: .statusTimer)
        let configuration = ScanConfiguration(roots: [root.path], maximumDepth: 3, includeLinkedWorktrees: true, ignoredDirectoryNames: [])
        // A fresh worker has no baseline for this configuration, so a status request must run as discovery.
        let outcome = await RepositoryRefreshWorker().run(RepositoryRefreshRequest(configuration: configuration, scope: .status(), diagnostics: context))
        XCTAssertTrue(outcome.scope.isDiscovery)

        let events = recorder.snapshot().events.filter { $0.requestID == context.id }
        let selected = try XCTUnwrap(events.first { $0.kind == .selected })
        XCTAssertEqual(selected.discovery, true)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.worktrees, 1, "discovery reports the checkouts its walk found")
        XCTAssertNotNil(selected.duration, "discovery reports the walk and rev-parse phase")
        let completed = try XCTUnwrap(events.last { $0.kind == .completed })
        XCTAssertEqual(completed.discovery, true, "completed reflects the scope that actually ran")
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.worktrees, 1)
        XCTAssertEqual(completed.failed, false)
        XCTAssertEqual(completed.commandCount, events.filter { $0.kind == .command }.count)
        XCTAssertEqual(events.filter { $0.kind == .repositoryCompleted }.count, 1)
        XCTAssertTrue(events.filter { $0.kind == .repositoryCompleted }.allSatisfy { $0.repository != nil })
        XCTAssertTrue(events.allSatisfy { $0.trigger == .statusTimer })
    }

    func testGitHubLoadCarriesContextAndCounterIntoConcurrentDetailBatches() {
        let runner = RecordingGitHubRunner()
        let context = PerformanceDiagnostics().context(trigger: .githubTimer)
        let counter = DiagnosticCommandCounter()
        let snapshot = DiagnosticContext.$current.withValue(context) {
            DiagnosticCommandCounter.$current.withValue(counter) {
                GitHubCLIService(runner: runner).loadPullRequests()
            }
        }
        XCTAssertEqual(snapshot.pullRequests.count, 2)
        let calls = runner.calls
        XCTAssertEqual(calls.filter { $0.command == "pr" }.count, 2, "both rows request details in one concurrent batch")
        XCTAssertTrue(calls.count >= 5, "auth, two searches, two detail loads, and a final auth check")
        XCTAssertTrue(calls.allSatisfy { $0.requestID == context.id && $0.trigger == .githubTimer }, "\(calls)")
        XCTAssertTrue(calls.allSatisfy(\.sawCounter), "the scan counter must reach detail loads on the scan queue")
        XCTAssertNil(DiagnosticContext.current)
    }
}

// Validate the versioned export without imposing JSONDecoder's default date format.
private struct JSONValue: Decodable {
    let schemaVersion: Int
    let capacity: Int
}

/// Captures the diagnostic context each GitHub CLI call observes, including calls made from
/// the concurrent detail batch, without touching the process-wide recorder.
private final class RecordingGitHubRunner: ProcessRunning, @unchecked Sendable {
    struct Call { var command: String; var requestID: UInt64?; var trigger: RefreshTrigger?; var sawCounter: Bool }
    private let lock = NSLock()
    private var storage: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return storage }

    func run(executable: String, arguments: [String]) -> ProcessResult {
        let context = DiagnosticContext.current
        lock.lock()
        storage.append(Call(command: arguments.first ?? "", requestID: context?.id, trigger: context?.trigger,
            sawCounter: DiagnosticCommandCounter.current != nil))
        lock.unlock()
        switch arguments.first {
        case "auth":
            return ProcessResult(standardOutput: "{\"hosts\":{\"github.com\":[{\"state\":\"success\",\"active\":true,\"login\":\"me\"}]}}", standardError: "", terminationStatus: 0)
        case "search":
            let review = arguments.contains("--review-requested=@me")
            let number = review ? 1 : 2
            return ProcessResult(standardOutput: """
            [{"number":\(number),"title":"Test","url":"https://github.com/org/repo/pull/\(number)","repository":{"nameWithOwner":"org/repo"},"author":{"login":"\(review ? "someone" : "me")"},"isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","commentsCount":0}]
            """, standardError: "", terminationStatus: 0)
        default:
            return ProcessResult(standardOutput: "", standardError: "", terminationStatus: 1)
        }
    }
}
