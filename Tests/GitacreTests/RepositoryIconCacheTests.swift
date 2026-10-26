import AppKit
import XCTest
@testable import Gitacre

@MainActor
final class RepositoryIconCacheTests: XCTestCase {
    override func setUp() async throws {
        RepositoryIconCache.shared.invalidate()
    }

    func testDecodesAnIconOnceAndServesItFromMemory() async throws {
        let icon = try makeIcon()
        let cache = RepositoryIconCache.shared

        let first = await cache.image(atPath: icon.path)
        XCTAssertNotNil(first)

        // Deleting the file proves the second lookup never reaches disk.
        try FileManager.default.removeItem(at: icon)
        let second = await cache.image(atPath: icon.path)
        XCTAssertIdentical(second, first)
    }

    func testInvalidateForcesTheNextLookupBackToDisk() async throws {
        let icon = try makeIcon()
        let cache = RepositoryIconCache.shared

        let initial = await cache.image(atPath: icon.path)
        XCTAssertNotNil(initial)
        cache.invalidate()
        try FileManager.default.removeItem(at: icon)

        let removed = await cache.image(atPath: icon.path)
        XCTAssertNil(removed, "a removed icon must not survive a rescan")
    }

    func testAPathThatCannotBeDecodedIsNotRetried() async throws {
        let directory = try makeDirectory()
        let broken = directory.appendingPathComponent("favicon.png")
        try Data("not an image".utf8).write(to: broken)
        let cache = RepositoryIconCache.shared

        let brokenImage = await cache.image(atPath: broken.path)
        XCTAssertNil(brokenImage)

        // Writing a real image now must not be picked up: the failure is remembered until
        // the next scan, which is what keeps a broken icon off the main thread every render.
        try makeIconData().write(to: broken)
        let cachedFailure = await cache.image(atPath: broken.path)
        XCTAssertNil(cachedFailure)

        cache.invalidate()
        let recovered = await cache.image(atPath: broken.path)
        XCTAssertNotNil(recovered)
    }

    func testAMissingPathResolvesToNothing() async {
        let missingPath = await RepositoryIconCache.shared.image(atPath: nil)
        let missingFile = await RepositoryIconCache.shared.image(atPath: "/nonexistent/favicon.png")
        XCTAssertNil(missingPath)
        XCTAssertNil(missingFile)
    }

    func testInvalidatedInFlightLoadCannotRestoreStaleImage() async {
        let entered = expectation(description: "background loader entered")
        let gate = IconLoadGate()
        let icon = LoadedRepositoryIcon(image: NSImage(size: NSSize(width: 16, height: 16)))
        let cache = RepositoryIconCache { _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            await gate.wait()
            return icon
        }
        let loading = Task { await cache.image(atPath: "/project/favicon.png") }
        await fulfillment(of: [entered], timeout: 2)
        cache.invalidate(paths: ["/project"])
        await gate.release()
        let result = await loading.value
        XCTAssertNil(result)
    }

    func testConcurrentRequestsShareOneBackgroundLoad() async {
        let entered = expectation(description: "background loader entered")
        let gate = IconLoadGate()
        let icon = LoadedRepositoryIcon(image: NSImage(size: NSSize(width: 16, height: 16)))
        let cache = RepositoryIconCache { _ in
            entered.fulfill()
            await gate.wait()
            return icon
        }
        let first = Task { await cache.image(atPath: "/project/favicon.png") }
        let second = Task { await cache.image(atPath: "/project/favicon.png") }
        await fulfillment(of: [entered], timeout: 2)
        await gate.release()
        let firstImage = await first.value
        let secondImage = await second.value
        XCTAssertIdentical(firstImage, icon.image)
        XCTAssertIdentical(secondImage, firstImage)
        let loads = await gate.arrivals
        XCTAssertEqual(loads, 1)
    }

    func testTargetedInvalidationKeepsOtherRepositoriesCached() async throws {
        let first = try makeIcon()
        let second = try makeIcon()
        let cache = RepositoryIconCache.shared
        _ = await cache.image(atPath: first.path)
        let kept = await cache.image(atPath: second.path)
        cache.invalidate(paths: [first.deletingLastPathComponent().path])
        try FileManager.default.removeItem(at: second)
        let cached = await cache.image(atPath: second.path)
        XCTAssertIdentical(cached, kept)
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeIcon() throws -> URL {
        let icon = try makeDirectory().appendingPathComponent("favicon.png")
        try makeIconData().write(to: icon)
        return icon
    }

    private func makeIconData() throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemBlue.drawSwatch(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        image.unlockFocus()
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}

private actor IconLoadGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
