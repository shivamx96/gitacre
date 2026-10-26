import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let standardOutput: String
    public let standardError: String
    public let terminationStatus: Int32

    public init(standardOutput: String, standardError: String, terminationStatus: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
    }

    public var succeeded: Bool {
        terminationStatus == 0
    }
}

public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String]) -> ProcessResult
}

public struct ProcessRunner: ProcessRunning {
    /// Ceiling on how long a single child process may run before it is terminated.
    ///
    /// Every caller reaches this type from a refresh that holds a loading flag for its
    /// duration, so a child that never exits would otherwise leave the app unable to
    /// refresh again for the rest of the session.
    public static let defaultTimeout: TimeInterval = 30

    /// Grace period between the polite `SIGTERM` and the unconditional `SIGKILL`.
    private static let terminationGracePeriod: TimeInterval = 2

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = ProcessRunner.defaultTimeout) {
        self.timeout = timeout
    }

    public func run(executable: String, arguments: [String]) -> ProcessResult {
        DiagnosticCommandCounter.current?.increment()
        let started = ProcessInfo.processInfo.systemUptime
        var exitStatus: Int32 = -1
        var failed = true
        var didTimeOut = false
        defer {
            let duration = ProcessInfo.processInfo.systemUptime - started
            ProcessDiagnostics.shared.record(duration: duration, failed: failed, timedOut: didTimeOut)
            PerformanceDiagnostics.shared.record(DiagnosticEvent(.command,
                command: DiagnosticCommand.classify(executable: executable, arguments: arguments),
                worktree: arguments.first == "-C" && arguments.count > 1 ? arguments[1].hashValue : nil,
                duration: duration, failed: failed, timedOut: didTimeOut, exitStatus: exitStatus))
        }
        let deadline = DispatchTime.now() + timeout
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return ProcessResult(
                standardOutput: "",
                standardError: error.localizedDescription,
                terminationStatus: -1
            )
        }

        // Both pipes must be drained while the child is still running. A pipe holds only
        // 64 KiB before `write` blocks, so a child that outgrows that buffer would hang
        // forever waiting for a reader that only starts once it exits.
        let output = ByteBuffer()
        let errorOutput = ByteBuffer()
        let draining = DispatchGroup()
        drain(standardOutput, into: output, until: deadline, group: draining)
        drain(standardError, into: errorOutput, until: deadline, group: draining)

        let childTimedOut = waitForExit(of: process, signalledBy: exited, until: deadline)
        draining.wait()
        let timedOut = childTimedOut || !output.reachedEOF || !errorOutput.reachedEOF
        process.waitUntilExit()

        exitStatus = process.terminationStatus
        didTimeOut = timedOut
        failed = timedOut || process.terminationStatus != 0
        if timedOut {
            return ProcessResult(
                standardOutput: String(decoding: output.value, as: UTF8.self),
                standardError: timeoutMessage(executable: executable, collected: errorOutput.value),
                terminationStatus: -1
            )
        }

        return ProcessResult(
            standardOutput: String(decoding: output.value, as: UTF8.self),
            standardError: String(decoding: errorOutput.value, as: UTF8.self),
            terminationStatus: process.terminationStatus
        )
    }

    /// Nonblocking readers share the command deadline. A descendant may inherit a pipe
    /// after the direct child exits; waiting for EOF must not keep a refresh alive forever.
    private func drain(_ pipe: Pipe, into buffer: ByteBuffer, until deadline: DispatchTime, group: DispatchGroup) {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            let handle = pipe.fileHandleForReading
            defer { try? handle.close() }
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return }
            var data = Data()
            var reachedEOF = false
            defer { buffer.set(data, reachedEOF: reachedEOF) }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while DispatchTime.now() < deadline {
                let count = read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    data.append(contentsOf: bytes.prefix(count))
                } else if count == 0 {
                    reachedEOF = true
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                    // A short poll bounds cleanup latency without spinning while a child is quiet.
                    _ = poll(&descriptorState, 1, 20)
                } else {
                    return
                }
            }
        }
    }

    /// Waits for the child to exit, escalating to `SIGTERM` then `SIGKILL` past the timeout.
    ///
    /// Returns `true` when the child had to be killed.
    private func waitForExit(of process: Process, signalledBy exited: DispatchSemaphore, until deadline: DispatchTime) -> Bool {
        guard exited.wait(timeout: deadline) == .timedOut else { return false }

        process.terminate()
        if exited.wait(timeout: .now() + Self.terminationGracePeriod) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
        return true
    }

    private func timeoutMessage(executable: String, collected: Data) -> String {
        let reason = "\(executable) did not finish within \(timeout)s; the command or its output exceeded the deadline."
        let collectedText = String(decoding: collected, as: UTF8.self)
        guard !collectedText.isEmpty else { return reason }
        return collectedText.hasSuffix("\n") ? collectedText + reason : collectedText + "\n" + reason
    }
}

/// Holds a pipe's contents while it is filled from a background queue and read from the caller.
private final class ByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var finished = false

    var reachedEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func set(_ data: Data, reachedEOF: Bool) {
        lock.lock()
        storage = data
        finished = reachedEOF
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
