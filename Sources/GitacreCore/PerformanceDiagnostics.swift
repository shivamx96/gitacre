import Foundation

public enum RefreshTrigger: String, Codable, Sendable, CaseIterable {
    case manual, startup, filesystem, statusTimer, discoveryTimer, githubTimer, wake, configuration, panel
    /// On-demand pull request detail loads for rows that became visible.
    case detail
}

public enum DiagnosticKind: String, Codable, Sendable {
    case requested, queued, combined, started, completed, superseded, published, publicationSkipped
    case repositoryCompleted, selected, command, filesystem, configuration, panelOpened, panelClosed, sleep, wake
    /// GitHub refresh lifecycle. A queued refresh runs once as a follow-up under the earliest queued ID.
    case githubRequested, githubQueued, githubCompleted, githubSkipped, githubPublished
}

public enum DiagnosticCommand: String, Codable, Sendable {
    case status, worktree, revParse, log, config, github, other

    static func classify(executable: String, arguments: [String]) -> Self {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if name == "gh" { return .github }
        guard name == "git" else { return .other }
        var args = arguments[...]
        if args.first == "-C" { args = args.dropFirst(2) }
        if args.first == "--no-optional-locks" { args = args.dropFirst() }
        switch args.first {
        case "status": return .status
        case "worktree": return .worktree
        case "rev-parse": return .revParse
        case "log": return .log
        case "config": return .config
        default: return .other
        }
    }
}

/// Carried explicitly across detached tasks and dispatch queues. No filesystem identity is retained.
public struct DiagnosticContext: Equatable, Sendable {
    public var id: UInt64
    public var trigger: RefreshTrigger
    public var since: TimeInterval
    public var repository: Int?
    @TaskLocal public static var current: DiagnosticContext?
}

/// Fixed-shape entries: no arbitrary strings, arrays, paths, arguments, or command output.
public struct DiagnosticEvent: Codable, Sendable {
    public var sequence: UInt64 = 0
    public var uptime: TimeInterval = 0
    public var kind: DiagnosticKind
    public var commandCount: Int?
    public var relatedRequestID: UInt64?
    public var automaticRefresh: Bool?
    public var githubPolling: Bool?
    /// Filesystem batch paths inside a `.git` directory, such as index or ref writes.
    public var insideGitDirectory: Int?
    public var requestID: UInt64?
    public var trigger: RefreshTrigger?
    public var repository: Int?
    public var worktree: Int?
    public var command: DiagnosticCommand?
    public var duration: TimeInterval?
    public var discovery: Bool?
    public var count: Int?
    public var worktrees: Int?
    public var failed: Bool?
    public var timedOut: Bool?
    public var exitStatus: Int32?
    public var changed: Bool?
    public var rescan: Bool?
    public var ignored: Int?
    public var refreshed: Bool?
    public var unmatched: Int?

    public init(_ kind: DiagnosticKind, context: DiagnosticContext? = DiagnosticContext.current,
                command: DiagnosticCommand? = nil, worktree: Int? = nil, duration: TimeInterval? = nil,
                discovery: Bool? = nil, count: Int? = nil, worktrees: Int? = nil,
                failed: Bool? = nil, timedOut: Bool? = nil, exitStatus: Int32? = nil,
                changed: Bool? = nil, commandCount: Int? = nil, relatedRequestID: UInt64? = nil, automaticRefresh: Bool? = nil, githubPolling: Bool? = nil, insideGitDirectory: Int? = nil, rescan: Bool? = nil, unmatched: Int? = nil, ignored: Int? = nil, refreshed: Bool? = nil) {
        self.ignored = ignored; self.refreshed = refreshed
        self.commandCount = commandCount
        self.relatedRequestID = relatedRequestID; self.automaticRefresh = automaticRefresh
        self.githubPolling = githubPolling; self.insideGitDirectory = insideGitDirectory
        self.kind = kind; requestID = context?.id; trigger = context?.trigger; repository = context?.repository
        self.worktree = worktree
        self.command = command; self.duration = duration; self.discovery = discovery
        self.count = count; self.worktrees = worktrees; self.failed = failed; self.timedOut = timedOut
        self.exitStatus = exitStatus; self.changed = changed; self.rescan = rescan; self.unmatched = unmatched
    }
}

public struct DiagnosticAggregate: Codable, Sendable {
    public var events = 0
    public var failures = 0
    public var timeouts = 0
    public var unchanged = 0
    public var totalCommands = 0
    public var totalInsideGitDirectory = 0
    public var discoveries = 0
    public var fullyIgnoredBatches = 0
    public var totalIgnored = 0
    public var refreshedBatches = 0
    public var totalUnmatched = 0
    public var totalCount = 0
    public var peakCount = 0
    public var totalDuration: TimeInterval = 0
    public var maximumDuration: TimeInterval = 0
    /// <= 10ms, 50ms, 100ms, 500ms, 1s, 5s, 30s, and >30s.
    public var durationBuckets = Array(repeating: 0, count: 8)

    mutating func add(_ event: DiagnosticEvent) {
        events += 1
        if event.failed == true { failures += 1 }
        if event.timedOut == true { timeouts += 1 }
        if event.changed == false { unchanged += 1 }
        totalCommands += event.commandCount ?? 0
        totalInsideGitDirectory += event.insideGitDirectory ?? 0
        if event.discovery == true { discoveries += 1 }
        if event.kind == .filesystem, let count = event.count, count > 0, event.ignored == count, event.rescan != true { fullyIgnoredBatches += 1 }
        totalIgnored += event.ignored ?? 0
        if event.refreshed == true { refreshedBatches += 1 }
        totalUnmatched += event.unmatched ?? 0
        totalCount += event.count ?? 0
        peakCount = max(peakCount, event.count ?? 0)
        if let duration = event.duration {
            totalDuration += duration
            maximumDuration = max(maximumDuration, duration)
            let bucket = [0.01, 0.05, 0.1, 0.5, 1, 5, 30].firstIndex { duration <= $0 } ?? 7
            durationBuckets[bucket] += 1
        }
    }
}

/// Process-wide CPU seconds from `getrusage`, read only at export. `children` covers every
/// reaped child process (git, gh) since launch. This is CPU time, not energy, and it is the
/// only CPU measure in the export; every `duration` elsewhere is elapsed wall time.
public struct DiagnosticCPUTime: Codable, Sendable, Equatable {
    public var selfUser: TimeInterval = 0
    public var selfSystem: TimeInterval = 0
    public var childrenUser: TimeInterval = 0
    public var childrenSystem: TimeInterval = 0

    static func current() -> Self {
        func seconds(_ value: timeval) -> TimeInterval { TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000 }
        var own = rusage(), children = rusage()
        var result = Self()
        if getrusage(RUSAGE_SELF, &own) == 0 { result.selfUser = seconds(own.ru_utime); result.selfSystem = seconds(own.ru_stime) }
        if getrusage(RUSAGE_CHILDREN, &children) == 0 { result.childrenUser = seconds(children.ru_utime); result.childrenSystem = seconds(children.ru_stime) }
        return result
    }
}

public struct DiagnosticSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let capturedAt: Date
    /// Awake seconds since recording started; `uptime` and `duration` fields share this clock,
    /// which does not advance while the Mac sleeps.
    public let elapsed: TimeInterval
    public let capacity: Int
    public let overwritten: UInt64
    public let processors: Int
    public let scanConcurrency: Int
    public let cpu: DiagnosticCPUTime
    public let aggregates: [String: DiagnosticAggregate]
    public let events: [DiagnosticEvent]
}

/// Constant-space, in-memory recording. Encoding and file I/O happen only on explicit export.
public final class PerformanceDiagnostics: @unchecked Sendable {
    public static let shared = PerformanceDiagnostics()
    private let lock = NSLock()
    private let sessionID = UUID()
    private let started = ProcessInfo.processInfo.systemUptime
    private var ring: [DiagnosticEvent?]
    private var next = 0
    private var sequence: UInt64 = 0
    private var requestID: UInt64 = 0
    // Keys use only finite enums, never repository/request identifiers, so the map is bounded.
    private struct AggregateKey: Hashable {
        var kind: DiagnosticKind
        var trigger: RefreshTrigger?
        var command: DiagnosticCommand?
        var name: String { [kind.rawValue, trigger?.rawValue ?? "none", command?.rawValue ?? "none"].joined(separator: ".") }
    }
    private var aggregates: [AggregateKey: DiagnosticAggregate] = [:]

    public init(capacity: Int = 2_000) {
        ring = Array(repeating: nil, count: max(1, min(capacity, 10_000)))
    }

    public func context(trigger: RefreshTrigger) -> DiagnosticContext {
        lock.lock(); defer { lock.unlock() }
        requestID += 1
        return DiagnosticContext(id: requestID, trigger: trigger, since: ProcessInfo.processInfo.systemUptime)
    }

    public func record(_ input: DiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        var event = input
        sequence += 1
        event.sequence = sequence
        event.uptime = ProcessInfo.processInfo.systemUptime - started
        if let duration = event.duration { event.duration = duration.isFinite ? max(0, duration) : nil }
        ring[next] = event
        next = (next + 1) % ring.count
        aggregates[AggregateKey(kind: event.kind, trigger: event.trigger, command: event.command), default: DiagnosticAggregate()].add(event)
    }

    public func snapshot() -> DiagnosticSnapshot {
        lock.lock(); defer { lock.unlock() }
        let events = (ring[next...] + ring[..<next]).compactMap { $0 }
        return DiagnosticSnapshot(schemaVersion: 1, sessionID: sessionID, capturedAt: Date(),
            elapsed: ProcessInfo.processInfo.systemUptime - started, capacity: ring.count,
            overwritten: sequence > UInt64(ring.count) ? sequence - UInt64(ring.count) : 0,
            processors: ProcessInfo.processInfo.activeProcessorCount,
            scanConcurrency: RepositoryScanner.concurrencyWidth, cpu: DiagnosticCPUTime.current(),
            aggregates: Dictionary(uniqueKeysWithValues: aggregates.map { ($0.key.name, $0.value) }), events: events)
    }

    public func exportJSON() throws -> Data {
        let snapshot = snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }
}

/// One counter per actual scan or GitHub load; released when that work completes, even
/// after timeline eviction. Only `ProcessRunner` increments it, so custom runners count zero.
public final class DiagnosticCommandCounter: @unchecked Sendable {
    @TaskLocal public static var current: DiagnosticCommandCounter?
    private let lock = NSLock()
    private var storage = 0
    public init() {}
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return storage }
}
