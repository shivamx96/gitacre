import XCTest
@testable import Gitacre

final class RepositoryWatcherTests: XCTestCase {
    func testEmptyWatcherIsInactiveForTimerFallback() {
        let watcher = RepositoryWatcher(paths: []) { _, _ in XCTFail("No stream should be installed") }
        XCTAssertFalse(watcher.isActive)
    }

    @MainActor
    func testFileChangesInvalidateTheWatchedTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = expectation(description: "FSEvents invalidates the changed path")
        changed.assertForOverFulfill = false
        let watcher = RepositoryWatcher(paths: [root.path]) { paths, _ in
            if paths.contains(where: { $0.contains(root.lastPathComponent) }) { changed.fulfill() }
        }
        XCTAssertTrue(watcher.isActive)
        try Data("change".utf8).write(to: root.appendingPathComponent("file.txt"))
        await fulfillment(of: [changed], timeout: 8)
        withExtendedLifetime(watcher) {}
    }
}
