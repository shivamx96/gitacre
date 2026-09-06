import AppKit

/// Keeps decoded repository icons in memory for the lifetime of a scan.
///
/// `RepositoryGlyph` is evaluated for every visible row, and SwiftUI re-evaluates a body
/// far more often than the data behind it changes — every hover, selection, scroll step,
/// and published property. Reading and decoding the icon inside `body` therefore put
/// synchronous disk reads on the main thread in the middle of a scrolling list.
@MainActor
final class RepositoryIconCache {
    static let shared = RepositoryIconCache()

    private var images: [String: NSImage] = [:]
    /// Paths that failed to decode, so a broken icon is not retried on every render.
    private var unreadablePaths: Set<String> = []

    private init() {}

    func image(atPath path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = images[path] { return cached }
        guard !unreadablePaths.contains(path) else { return nil }

        guard let image = NSImage(contentsOfFile: path) else {
            unreadablePaths.insert(path)
            return nil
        }
        images[path] = image
        return image
    }

    /// Drops everything so a rescan picks up icons that were added, replaced, or removed.
    ///
    /// Bounds staleness to one scan interval without paying a `stat` on every render.
    func invalidate() {
        images.removeAll(keepingCapacity: true)
        unreadablePaths.removeAll(keepingCapacity: true)
    }
}
