import Foundation

/// Session counters contain no arguments, paths, remote URLs, or subprocess output.
public final class ProcessDiagnostics: @unchecked Sendable {
    public static let shared = ProcessDiagnostics()
    private let lock = NSLock()
    private var commands = 0
    private var failures = 0
    private var timeouts = 0
    private var slowest: TimeInterval = 0

    func record(duration: TimeInterval, failed: Bool, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        commands += 1
        if failed { failures += 1 }
        if timedOut { timeouts += 1 }
        slowest = max(slowest, duration)
    }

    public var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "Session commands: \(commands); failures: \(failures); timeouts: \(timeouts); slowest command: \(String(format: "%.2fs", slowest))"
    }
}
