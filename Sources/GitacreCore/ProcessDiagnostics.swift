import Foundation

/// Session counters contain no arguments, paths, remote URLs, or subprocess output.
public final class ProcessDiagnostics: @unchecked Sendable {
    public static let shared = ProcessDiagnostics()
    private let lock = NSLock()
    private var commands = 0
    private var failures = 0
    private var timeouts = 0
    private var slowest: TimeInterval = 0
    private var discoveryDuration: TimeInterval?
    private var statusDuration: TimeInterval?
    private var slowestRepository: TimeInterval = 0

    func recordScan(duration: TimeInterval, discovery: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if discovery { discoveryDuration = duration } else { statusDuration = duration }
    }

    func recordRepository(duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        slowestRepository = max(slowestRepository, duration)
    }

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
        let discovery = discoveryDuration.map { String(format: "%.2fs", $0) } ?? "none"
        let status = statusDuration.map { String(format: "%.2fs", $0) } ?? "none"
        return "Last discovery: \(discovery); last status refresh: \(status); slowest repository (anonymous): \(String(format: "%.2fs", slowestRepository))\nSession commands: \(commands); failures: \(failures); timeouts: \(timeouts); slowest command: \(String(format: "%.2fs", slowest))"
    }
}
