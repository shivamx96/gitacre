import Foundation

/// Serializes asynchronous refresh work so overlapping requests coalesce.
///
/// While work is in flight, further `submit` calls replace a single pending follow-up
/// instead of starting a parallel scan or returning immediately. Completed work is
/// published only when no newer request has superseded it; stale results never become
/// visible even if the underlying git processes are left to finish.
///
/// `perform` must not block this actor. Long-running work belongs in a detached task
/// so overlapping submits can enqueue while a scan is running.
public actor RefreshCoordinator<Request: Sendable, Value: Sendable> {
    public typealias Coalesce = @Sendable (Request, Request) -> Request
    public typealias Perform = @Sendable (Request) async -> Value

    public typealias Covers = @Sendable (Request, Request) -> Bool

    private let coalesce: Coalesce
    private let covers: Covers
    private let perform: Perform

    private var running = false
    private var generation: UInt64 = 0
    private var pending: PendingRequest?
    private var inFlight: PendingRequest?
    private var waiters: [CheckedContinuation<Value, Never>] = []
    private var waiterCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    private struct PendingRequest {
        var generation: UInt64
        var request: Request
    }

    public init(
        coalesce: @escaping Coalesce,
        covers: @escaping Covers = { _, _ in false },
        perform: @escaping Perform
    ) {
        self.coalesce = coalesce
        self.covers = covers
        self.perform = perform
    }

    /// Enqueue `request` and wait until a non-superseded run that includes it finishes.
    ///
    /// Every waiter waiting at publish time receives the same value — the result of the
    /// latest non-superseded request, not necessarily the request they originally submitted.
    @discardableResult
    public func submit(_ request: Request) async -> Value {
        if let pending {
            generation += 1
            self.pending = PendingRequest(
                generation: generation,
                request: coalesce(pending.request, request)
            )
        } else if let inFlight {
            if covers(inFlight.request, request) {
                // The active run already includes this request; just wait for it.
            } else {
                // The active run is now superseded and its result will be discarded, so
                // fold its request into the follow-up. Dropping it here would lose the
                // work it represents — a targeted status refresh of another repository,
                // or a discovery the new configuration no longer covers.
                generation += 1
                pending = PendingRequest(
                    generation: generation,
                    request: coalesce(inFlight.request, request)
                )
            }
        } else {
            generation += 1
            pending = PendingRequest(generation: generation, request: request)
        }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            notifyWaiterCountObservers()
            Task { await self.drain() }
        }
    }

    public var isRunning: Bool { running }

    var waiterCount: Int { waiters.count }

    func waitUntilWaiterCount(_ count: Int) async {
        if waiters.count >= count { return }
        await withCheckedContinuation { continuation in
            waiterCountWaiters.append((count, continuation))
        }
    }

    private func notifyWaiterCountObservers() {
        waiterCountWaiters.removeAll { target, continuation in
            guard waiters.count >= target else { return false }
            continuation.resume()
            return true
        }
    }

    private func drain() async {
        guard !running else { return }
        running = true
        defer { running = false }

        while let next = pending {
            pending = nil
            inFlight = next
            let startedGeneration = next.generation
            let value = await perform(next.request)
            inFlight = nil
            // `submit` cannot interleave here: this actor is isolated again only after
            // `perform` returns, so a newer request would already have stored `pending`
            // and incremented `generation`.
            if pending != nil || startedGeneration != generation {
                continue
            }
            let currentWaiters = waiters
            waiters = []
            for waiter in currentWaiters {
                waiter.resume(returning: value)
            }
        }
    }
}
