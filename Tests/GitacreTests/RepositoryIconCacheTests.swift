import AppKit
import XCTest
@testable import Gitacre

@MainActor
final class RepositoryIconCacheTests: XCTestCase {
    override func setUp() async throws {
        RepositoryIconCache.shared.invalidate()
    }

    func testDecodesAnIconOnceAndServesItFromMemory() throws {
        let icon = try makeIcon()
        let cache = RepositoryIconCache.shared

        let first = cache.image(atPath: icon.path)
        XCTAssertNotNil(first)

        // Deleting the file proves the second lookup never reaches disk.
        try FileManager.default.removeItem(at: icon)
        XCTAssertIdentical(cache.image(atPath: icon.path), first)
    }

    func testInvalidateForcesTheNextLookupBackToDisk() throws {
        let icon = try makeIcon()
        let cache = RepositoryIconCache.shared

        XCTAssertNotNil(cache.image(atPath: icon.path))
        cache.invalidate()
        try FileManager.default.removeItem(at: icon)

        XCTAssertNil(cache.image(atPath: icon.path), "a removed icon must not survive a rescan")
    }

    func testAPathThatCannotBeDecodedIsNotRetried() throws {
        let directory = try makeDirectory()
        let broken = directory.appendingPathComponent("favicon.png")
        try Data("not an image".utf8).write(to: broken)
        let cache = RepositoryIconCache.shared

        XCTAssertNil(cache.image(atPath: broken.path))

        // Writing a real image now must not be picked up: the failure is remembered until
        // the next scan, which is what keeps a broken icon off the main thread every render.
        try makeIconData().write(to: broken)
        XCTAssertNil(cache.image(atPath: broken.path))

        cache.invalidate()
        XCTAssertNotNil(cache.image(atPath: broken.path))
    }

    func testAMissingPathResolvesToNothing() {
        XCTAssertNil(RepositoryIconCache.shared.image(atPath: nil))
        XCTAssertNil(RepositoryIconCache.shared.image(atPath: "/nonexistent/favicon.png"))
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
