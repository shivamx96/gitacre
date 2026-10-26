import Foundation
import XCTest
@testable import GitacreCore

final class RepositoryDiscoveryTests: XCTestCase {
    func testMissingRootDoesNotHideHealthyRepositoriesOrDuplicateIssues() throws {
        let root = try temporaryDirectory()
        let healthy = root.appendingPathComponent("healthy")
        let missing = root.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        XCTAssertTrue(ProcessRunner().run(executable: "/usr/bin/git", arguments: ["-C", healthy.path, "init", "-q"]).succeeded)
        let result = RepositoryScanner().scanWithIssues(roots: [healthy.path, missing.path, missing.path])
        XCTAssertEqual(result.repositories.map(\.name), ["healthy"])
        XCTAssertEqual(result.discoveryIssues.map(\.path), [missing.standardizedFileURL.path])
    }

    func testFileInPlaceOfMonitoredDirectoryProducesIssue() throws {
        let file = try temporaryDirectory().appendingPathComponent("not-a-folder")
        try Data().write(to: file)
        let result = RepositoryScanner().scanWithIssues(roots: [file.path])
        XCTAssertTrue(result.repositories.isEmpty)
        XCTAssertEqual(result.discoveryIssues.count, 1)
    }

    func testUnreadableSubdirectoryIsReportedWhileAccessibleSiblingsAreScanned() throws {
        let root = try temporaryDirectory()
        let blocked = root.appendingPathComponent("blocked")
        let healthy = root.appendingPathComponent("healthy")
        for directory in [blocked, healthy] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        XCTAssertTrue(ProcessRunner().run(executable: "/usr/bin/git", arguments: ["-C", healthy.path, "init", "-q"]).succeeded)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        guard !FileManager.default.isReadableFile(atPath: blocked.path) else {
            throw XCTSkip("This user can bypass directory permissions")
        }
        let result = RepositoryScanner().scanWithIssues(roots: [root.path])
        XCTAssertEqual(result.repositories.map(\.name), ["healthy"])
        XCTAssertFalse(result.discoveryIssues.isEmpty)
        XCTAssertTrue(result.discoveryIssues.contains { $0.path.hasSuffix("/blocked") })
    }

    func testIssuesPersistThroughStatusAndClearOnlyAfterSuccessfulDiscovery() async throws {
        let root = try temporaryDirectory().appendingPathComponent("missing")
        let config = ScanConfiguration(roots: [root.path], maximumDepth: 3, includeLinkedWorktrees: true, ignoredDirectoryNames: [])
        let worker = RepositoryRefreshWorker()
        let discovery = await worker.run(RepositoryRefreshRequest(configuration: config, scope: .discovery))
        XCTAssertEqual(discovery.discoveryIssues.count, 1)
        let status = await worker.run(RepositoryRefreshRequest(configuration: config, scope: .status()))
        XCTAssertEqual(status.discoveryIssues, discovery.discoveryIssues)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recovered = await worker.run(RepositoryRefreshRequest(configuration: config, scope: .discovery))
        XCTAssertTrue(recovered.discoveryIssues.isEmpty)
    }

    func testSnapshotPersistsIssuesAndReadsOlderSnapshots() throws {
        let cache = try temporaryDirectory().appendingPathComponent("snapshot.json")
        let config = ScanConfiguration(roots: ["/missing"], maximumDepth: 3, includeLinkedWorktrees: true, ignoredDirectoryNames: [])
        let issues = [RepositoryDiscoveryIssue(path: "/missing", message: "Folder missing")]
        LocalSnapshot(configuration: config, repositories: [], fetchedAt: Date(), discoveryIssues: issues).write(to: cache)
        XCTAssertEqual(LocalSnapshot.read(at: cache, configuration: config)?.discoveryIssues, issues)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        legacy.removeValue(forKey: "discoveryIssues")
        try JSONSerialization.data(withJSONObject: legacy).write(to: cache)
        let loaded = try XCTUnwrap(LocalSnapshot.read(at: cache, configuration: config))
        XCTAssertNil(loaded.discoveryIssues)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
