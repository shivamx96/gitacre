import Foundation

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
        drain(standardOutput, into: output, group: draining)
        drain(standardError, into: errorOutput, group: draining)

        let timedOut = waitForExit(of: process, signalledBy: exited)
        draining.wait()
        process.waitUntilExit()

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

    private func drain(_ pipe: Pipe, into buffer: ByteBuffer, group: DispatchGroup) {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            buffer.set(pipe.fileHandleForReading.readDataToEndOfFile())
        }
    }

    /// Waits for the child to exit, escalating to `SIGTERM` then `SIGKILL` past the timeout.
    ///
    /// Returns `true` when the child had to be killed.
    private func waitForExit(of process: Process, signalledBy exited: DispatchSemaphore) -> Bool {
        guard exited.wait(timeout: .now() + timeout) == .timedOut else { return false }

        process.terminate()
        if exited.wait(timeout: .now() + Self.terminationGracePeriod) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
        return true
    }

    private func timeoutMessage(executable: String, collected: Data) -> String {
        let reason = "\(executable) did not finish within \(Int(timeout))s and was terminated."
        let collectedText = String(decoding: collected, as: UTF8.self)
        guard !collectedText.isEmpty else { return reason }
        return collectedText.hasSuffix("\n") ? collectedText + reason : collectedText + "\n" + reason
    }
}

/// Holds a pipe's contents while it is filled from a background queue and read from the caller.
private final class ByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
