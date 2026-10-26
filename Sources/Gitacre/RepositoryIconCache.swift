import AppKit
import ImageIO

/// Immutable images created by a worker, then only read by the UI.
struct LoadedRepositoryIcon: @unchecked Sendable {
    let image: NSImage?
}

/// Coalesces icon loads and keeps disk reads and raster decoding off the main actor.
@MainActor
final class RepositoryIconCache: ObservableObject {
    static let shared = RepositoryIconCache()
    @Published private(set) var revision: UInt64 = 0

    private struct Pending {
        let id = UUID()
        let task: Task<LoadedRepositoryIcon, Never>
    }
    private var images: [String: NSImage] = [:]
    private var unreadablePaths: Set<String> = []
    private var pending: [String: Pending] = [:]
    private let loader: @Sendable (String) async -> LoadedRepositoryIcon

    init(loader: @escaping @Sendable (String) async -> LoadedRepositoryIcon = { path in
        // Decode small raster thumbnails before publication; a 19-point glyph never
        // needs a full-resolution project image. NSImage covers formats such as SVG.
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            return LoadedRepositoryIcon(image: NSImage(cgImage: thumbnail, size: .zero))
        }
        return LoadedRepositoryIcon(image: NSImage(contentsOfFile: path))
    }) {
        self.loader = loader
    }

    func image(atPath path: String?) async -> NSImage? {
        guard let path else { return nil }
        if let cached = images[path] { return cached }
        guard !unreadablePaths.contains(path) else { return nil }
        let request: Pending
        if let active = pending[path] {
            request = active
        } else {
            let loader = self.loader
            request = Pending(task: Task.detached(priority: .utility) { await loader(path) })
            pending[path] = request
        }
        let loaded = await request.task.value
        // Invalidation may remove this request while it is reading. Never let an old
        // completion overwrite a newer icon or restore an invalidated cache entry.
        guard pending[path]?.id == request.id else { return images[path] }
        pending[path] = nil
        if let image = loaded.image {
            images[path] = image
        } else {
            unreadablePaths.insert(path)
        }
        return loaded.image
    }

    func invalidate(paths: Set<String>) {
        let known = Set(images.keys).union(unreadablePaths).union(pending.keys)
        for path in known where paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            images.removeValue(forKey: path)
            unreadablePaths.remove(path)
            pending.removeValue(forKey: path)?.task.cancel()
        }
        revision &+= 1
    }

    func invalidate() {
        images.removeAll(keepingCapacity: true)
        unreadablePaths.removeAll(keepingCapacity: true)
        for request in pending.values { request.task.cancel() }
        pending.removeAll()
        revision &+= 1
    }
}
