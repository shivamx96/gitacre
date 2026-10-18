import XCTest
@testable import Gitacre

final class RepositoryWatcherTests: XCTestCase {
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
        try Data("change".utf8).write(to: root.appendingPathComponent("file.txt"))
        await fulfillment(of: [changed], timeout: 8)
        withExtendedLifetime(watcher) {}
    }
}
