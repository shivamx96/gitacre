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
}

// Validate the versioned export without imposing JSONDecoder's default date format.
private struct JSONValue: Decodable {
    let schemaVersion: Int
    let capacity: Int
}
