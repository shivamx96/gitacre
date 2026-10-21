import Foundation

/// Pure decisions shared by the watcher and deterministic policy tests.
public enum BackgroundRefreshPolicy {
    public static func needsPanelRefresh(lastSuccess: Date?, now: Date = Date(), maximumAge: TimeInterval, stale: Bool = false) -> Bool {
        guard !stale, let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= maximumAge
    }

    public static func accepts(path: String, commonDirectories: [String] = []) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let components = path.split(separator: "/").map(String.init)
        let relative: String
        if let index = components.firstIndex(of: ".git") {
            relative = components.dropFirst(index + 1).joined(separator: "/")
        } else if let directory = commonDirectories.sorted(by: { $0.count > $1.count }).first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            relative = path == directory ? "" : String(path.dropFirst(directory.count + 1))
        } else {
            return true // Worktree files, including files named *.lock, are visible changes.
        }
        if relative.split(separator: "/").contains(where: { $0.hasSuffix(".lock") }) { return false }
        if relative.isEmpty { return true } // Creation/removal of .git, or a coalesced directory event.
        let exact: Set<String> = ["HEAD", "index", "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "packed-refs", "logs/refs/stash"]
        return exact.contains(relative) || ["rebase-merge", "rebase-apply", "refs", "worktrees"].contains {
            relative == $0 || relative.hasPrefix($0 + "/")
        }
    }

    public struct Batch: Sendable {
        public let paths: Set<String>
        public let ignored: Int
        public let unmatched: Int
        public let needsDiscovery: Bool
        public let statusScope: RepositoryRefreshScope?
    }

    public static func batch(paths: Set<String>, rescan: Bool, repositories: [Repository]) -> Batch {
        let paths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let accepted = paths.filter { accepts(path: $0, commonDirectories: repositories.map(\.commonDirectory)) }
        // Parent/root events are not "inside" a known repo: a sibling clone may have appeared.
        let unmatched = accepted.filter { path in
            !repositories.contains { repository in
                ([repository.commonDirectory] + repository.worktrees.map(\.path)).contains { directory in
                    let directory = URL(fileURLWithPath: directory).standardizedFileURL.path
                    return path == directory || path.hasPrefix(directory + "/")
                }
            }
        }.count
        let matched = accepted.filter { path in repositories.contains { $0.isAffected(byChangedPath: path) } }
        return Batch(paths: accepted, ignored: paths.count - accepted.count, unmatched: unmatched,
            needsDiscovery: rescan || unmatched > 0,
            statusScope: rescan ? .status() : (matched.isEmpty ? nil : .status(paths: matched)))
    }
}

/// A trailing deadline, never extended by subsequent noise. Startup/manual scans bypass it.
public struct DiscoveryDebounce: Sendable {
    public private(set) var deadline: TimeInterval?
    private var lastDiscovery: TimeInterval?
    public init() {}
    public mutating func didStartDiscovery(at now: TimeInterval) {
        lastDiscovery = now
        deadline = nil
    }
    public mutating func request(at now: TimeInterval) -> TimeInterval {
        if let deadline { return deadline }
        let due = max(now + 1, (lastDiscovery ?? now) + 60)
        deadline = due
        return due
    }
}
