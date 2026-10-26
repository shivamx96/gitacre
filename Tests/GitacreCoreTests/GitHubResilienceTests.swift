import XCTest
@testable import GitacreCore

final class GitHubResilienceTests: XCTestCase {
    func testPartialFailureRetainsOnlyFailedCategoryAndScopesCacheToAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("gh")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let cache = directory.appendingPathComponent("cache.json")
        let runner = ResilienceRunner()
        let service = GitHubCLIService(runner: runner)
        let first = service.loadPullRequests(preferredPath: executable.path, cacheURL: cache, organizations: ["org"])
        XCTAssertEqual(first.pullRequests.count, 2)
        XCTAssertTrue(runner.searches.allSatisfy { $0.contains("1000") && $0.contains("--owner") && $0.contains("org") })
        runner.failReviews = true
        runner.emptyAuthored = true
        let second = service.loadPullRequests(preferredPath: executable.path, cacheURL: cache, organizations: ["org"])
        XCTAssertEqual(second.pullRequests.map(\.kind), [.reviewRequested])
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        XCTAssertNotNil(second.errorMessage)
        runner.login = "other"
        XCTAssertTrue(service.loadPullRequests(preferredPath: executable.path, cacheURL: cache, organizations: ["org"]).pullRequests.isEmpty)
    }

    func testAuthOutagePreservesCacheWithoutExposingAnUnverifiedAccountsPRs() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let runner = ResilienceRunner()
        let service = GitHubCLIService(runner: runner)
        let initial = service.loadPullRequests(preferredPath: "/usr/bin/true", cacheURL: cache)
        let bytes = try Data(contentsOf: cache)
        runner.failAuth = true
        let outage = service.loadPullRequests(preferredPath: "/usr/bin/true", cacheURL: cache)
        guard case .unavailable = outage.authentication else { return XCTFail("Expected unavailable") }
        XCTAssertTrue(outage.pullRequests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: cache), bytes)

        // Once identity is verified again, failed categories can reuse the same cache.
        runner.failAuth = false
        runner.failReviews = true
        let recovered = service.loadPullRequests(preferredPath: "/usr/bin/true", cacheURL: cache)
        XCTAssertEqual(recovered.pullRequests.map(\.id).sorted(), initial.pullRequests.map(\.id).sorted())
    }

    func testMalformedSearchDoesNotBecomeSuccessfulEmptyResult() throws {
        let runner = ResilienceRunner()
        runner.malformed = true
        let snapshot = GitHubCLIService(runner: runner).loadPullRequests(preferredPath: "/usr/bin/true")
        XCTAssertNotNil(snapshot.errorMessage)
        XCTAssertNil(snapshot.fetchedAt)
    }
}

private final class ResilienceRunner: ProcessRunning, @unchecked Sendable {
    var failAuth = false
    var failReviews = false
    var emptyAuthored = false
    var malformed = false
    var login = "me"
    var searches: [[String]] = []
    func run(executable: String, arguments: [String]) -> ProcessResult {
        if arguments.first == "auth" {
            if failAuth { return result("", status: -1) }
            return result("{\"hosts\":{\"github.com\":[{\"state\":\"success\",\"active\":true,\"login\":\"\(login)\"}]}}")
        }
        if arguments.first == "search" {
            searches.append(arguments)
            let review = arguments.contains("--review-requested=@me")
            if review && failReviews { return result("", status: 1) }
            if malformed { return result("not json") }
            if !review && emptyAuthored { return result("[]") }
            let number = review ? 1 : 2
            return result("""
            [{"number":\(number),"title":"Test","url":"https://github.com/org/repo/pull/\(number)","repository":{"nameWithOwner":"org/repo"},"author":{"login":"\(review ? "someone" : login)"},"isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","commentsCount":0}]
            """)
        }
        return result("", status: 1)
    }
    private func result(_ output: String, status: Int32 = 0) -> ProcessResult {
        ProcessResult(standardOutput: output, standardError: "", terminationStatus: status)
    }
}
