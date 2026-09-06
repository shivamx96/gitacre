import Foundation
import XCTest
@testable import GitacreCore

final class ProcessRunnerTests: XCTestCase {
    /// Comfortably larger than the 64 KiB a pipe buffers before `write` blocks.
    private static let payloadSize = 1 << 20

    func testReadsStandardOutputLargerThanThePipeBuffer() throws {
        let payload = try makePayloadFile()

        let result = try runWithinTestTimeout {
            ProcessRunner().run(executable: "/bin/cat", arguments: [payload.path])
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput.utf8.count, Self.payloadSize)
        XCTAssertEqual(result.standardError, "")
    }

    func testReadsStandardErrorLargerThanThePipeBuffer() throws {
        let payload = try makePayloadFile()

        let result = try runWithinTestTimeout {
            ProcessRunner().run(
                executable: "/bin/sh",
                arguments: ["-c", #"cat "$1" >&2"#, "sh", payload.path]
            )
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(result.standardError.utf8.count, Self.payloadSize)
    }

    /// Draining the pipes one after another deadlocks whenever both outgrow their buffer,
    /// because whichever pipe is read second stays full while the child blocks writing to it.
    func testReadsBothPipesWhenEachExceedsThePipeBuffer() throws {
        let payload = try makePayloadFile()

        let result = try runWithinTestTimeout {
            ProcessRunner().run(
                executable: "/bin/sh",
                arguments: ["-c", #"cat "$1"; cat "$1" >&2"#, "sh", payload.path]
            )
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput.utf8.count, Self.payloadSize)
        XCTAssertEqual(result.standardError.utf8.count, Self.payloadSize)
    }

    func testTerminatesAChildThatOutlivesTheTimeout() throws {
        let started = Date()

        let result = try runWithinTestTimeout {
            ProcessRunner(timeout: 1).run(executable: "/bin/sleep", arguments: ["45"])
        }

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.terminationStatus, -1)
        XCTAssertTrue(result.standardError.contains("did not finish within 1s"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testReportsAFailureWhenTheExecutableIsMissing() throws {
        let result = try runWithinTestTimeout {
            ProcessRunner().run(executable: "/nonexistent/gitacre-tool", arguments: [])
        }

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.terminationStatus, -1)
    }

    func testReportsTheChildExitCode() throws {
        let result = try runWithinTestTimeout {
            ProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "exit 3"])
        }

        XCTAssertEqual(result.terminationStatus, 3)
    }

    // MARK: - Helpers

    private func makePayloadFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let payload = directory.appendingPathComponent("payload.txt")
        try Data(repeating: UInt8(ascii: "x"), count: Self.payloadSize).write(to: payload)
        return payload
    }

    /// Runs `work` off the test thread so a regression fails the test instead of hanging it.
    private func runWithinTestTimeout(
        _ timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line,
        work: @escaping @Sendable () -> ProcessResult
    ) throws -> ProcessResult {
        let finished = expectation(description: "ProcessRunner returned")
        let box = ResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            finished.fulfill()
        }

        guard XCTWaiter().wait(for: [finished], timeout: timeout) == .completed else {
            XCTFail("ProcessRunner did not return within \(timeout)s", file: file, line: line)
            throw CancellationError()
        }
        return try XCTUnwrap(box.value, file: file, line: line)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ProcessResult?

    var value: ProcessResult? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
