import Foundation
import XCTest
@testable import GitacreCore

final class GitHubCLIServiceTests: XCTestCase {
    func testReportsActiveCLIAccountWithoutReadingToken() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let executable = temporaryDirectory.appendingPathComponent("gh")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let output = #"{"hosts":{"github.com":[{"state":"success","active":true,"login":"octocat"}]}}"#
        let runner = StubRunner(result: ProcessResult(
            standardOutput: output,
            standardError: "",
            terminationStatus: 0
        ))
        let service = GitHubCLIService(runner: runner)

        XCTAssertEqual(
            service.authentication(preferredPath: executable.path),
            .signedIn(executable: executable.path, login: "octocat")
        )
        XCTAssertEqual(runner.recordedArguments, [
            "auth", "status", "--active", "--hostname", "github.com", "--json", "hosts"
        ])
    }
}

private final class StubStorage: @unchecked Sendable {
    var arguments: [String] = []
}

private struct StubRunner: ProcessRunning {
    let result: ProcessResult
    private let storage = StubStorage()

    var recordedArguments: [String] { storage.arguments }

    func run(executable: String, arguments: [String]) -> ProcessResult {
        storage.arguments = arguments
        return result
    }
}
