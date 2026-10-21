import Foundation

/// Session-only negative results. The scanner's existing HEAD observation prevents an
/// unborn branch memo from hiding a first commit or a different linked worktree's HEAD.
public final class RepositoryFailureMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var missingOrigins = Set<String>()
    private var unbornHeads: [String: Set<String>] = [:]
    public init() {}
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        missingOrigins.removeAll()
        unbornHeads.removeAll()
    }
    func originIsAbsent(_ commonDirectory: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return missingOrigins.contains(commonDirectory)
    }
    func rememberMissingOrigin(_ commonDirectory: String) {
        lock.lock(); defer { lock.unlock() }
        missingOrigins.insert(commonDirectory)
    }
    func skipsLog(_ commonDirectory: String, checkout: String, unborn: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return unborn && unbornHeads[commonDirectory, default: []].contains(checkout)
    }
    func rememberUnbornHead(_ commonDirectory: String, checkout: String) {
        lock.lock(); defer { lock.unlock() }
        unbornHeads[commonDirectory, default: []].insert(checkout)
    }
}
