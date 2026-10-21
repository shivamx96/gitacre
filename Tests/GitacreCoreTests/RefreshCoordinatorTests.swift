import XCTest
@testable import GitacreCore

final class RefreshCoordinatorTests: XCTestCase {
    func testOverlappingRequestsCoalesceIntoOneFollowUpAndDiscardStaleResults() async {
        let gate = AsyncGate()
        let diagnostics = PerformanceDiagnostics()
        let performed = ValueLog<Int>()
        let coordinator = RefreshCoordinator<Int, Int>(
            coalesce: { _, next in next },
            observe: { kind, request, related, count in
                let context = DiagnosticContext(id: UInt64(request), trigger: .manual, since: 0)
                diagnostics.record(DiagnosticEvent(kind, context: context, count: count,
                    relatedRequestID: related.map(UInt64.init)))
            },
            perform: { request in
                await performed.append(request)
                if request == 1 {
                    await gate.wait()
                }
                return request * 10
            }
        )

        let first = Task { await coordinator.submit(1) }
        await gate.waitUntilEntered()
        let second = Task { await coordinator.submit(2) }
        // Wait for each submit to register before starting the next: `coalesce` here keeps
        // the later request, so the assertions below depend on 2 landing before 3.
        await coordinator.waitUntilWaiterCount(2)
        let third = Task { await coordinator.submit(3) }
        await coordinator.waitUntilWaiterCount(3)
        await gate.open()

        let values = await (first.value, second.value, third.value)
        let performedValues = await performed.values
        XCTAssertEqual(values.0, 30)
        XCTAssertEqual(values.1, 30)
        XCTAssertEqual(values.2, 30)
        XCTAssertEqual(performedValues, [1, 3])
        let events = diagnostics.snapshot().events
        XCTAssertEqual(events.map(\.kind), [.started, .queued, .combined, .superseded, .started])
        XCTAssertEqual(events.first { $0.kind == .queued }?.relatedRequestID, 1)
        XCTAssertEqual(events.first { $0.kind == .combined }?.relatedRequestID, 2)
        XCTAssertEqual(events.last?.count, 3)
    }

    /// A follow-up that absorbs the superseded in-flight request keeps that request's ID,
    /// trigger and start time, so published latency counts from the earliest caller while the
    /// merged scope reflects every request it carries.
    func testCoalescedFollowUpKeepsEarliestIdentityAndMergedScope() async throws {
        let gate = AsyncGate()
        let diagnostics = PerformanceDiagnostics()
        let configuration = ScanConfiguration(roots: ["/tmp"], maximumDepth: 3, includeLinkedWorktrees: true, ignoredDirectoryNames: [])
        let coordinator = RefreshCoordinator<RepositoryRefreshRequest, RepositoryRefreshOutcome>(
            coalesce: { $0.coalescing($1) },
            covers: { $0.covers($1) },
            observe: { kind, request, related, count in
                diagnostics.record(DiagnosticEvent(kind, context: request.diagnostics,
                    discovery: request.scope.isDiscovery, count: count, relatedRequestID: related?.diagnostics?.id))
            },
            perform: { request in
                if request.diagnostics?.trigger == .statusTimer, !request.scope.isDiscovery { await gate.wait() }
                return RepositoryRefreshOutcome(repositories: [], scope: request.scope, diagnostics: request.diagnostics)
            }
        )
        let timer = diagnostics.context(trigger: .statusTimer)
        let filesystem = diagnostics.context(trigger: .filesystem)

        let first = Task { await coordinator.submit(RepositoryRefreshRequest(configuration: configuration, scope: .status(), diagnostics: timer)) }
        await gate.waitUntilEntered()
        let second = Task { await coordinator.submit(RepositoryRefreshRequest(configuration: configuration, scope: .discovery, diagnostics: filesystem)) }
        await coordinator.waitUntilWaiterCount(2)
        await gate.open()

        let outcomes = await (first.value, second.value)
        XCTAssertEqual(outcomes.0.diagnostics, timer, "the follow-up runs under the earliest request")
        XCTAssertEqual(outcomes.1.diagnostics, timer)
        XCTAssertTrue(outcomes.1.scope.isDiscovery)

        let events = diagnostics.snapshot().events
        XCTAssertEqual(events.map(\.kind), [.started, .queued, .superseded, .started])
        XCTAssertEqual(events.map(\.requestID), [timer.id, filesystem.id, timer.id, timer.id])
        let queued = try XCTUnwrap(events.first { $0.kind == .queued })
        XCTAssertEqual(queued.relatedRequestID, timer.id)
        XCTAssertEqual(queued.trigger, .filesystem)
        XCTAssertEqual(queued.discovery, true)
        let followUp = try XCTUnwrap(events.last)
        XCTAssertEqual(followUp.trigger, .statusTimer, "trigger attribution stays with the earliest request")
        XCTAssertEqual(followUp.discovery, true, "scope is the merged scope, not the earliest request's")
        XCTAssertEqual(followUp.count, 2)
    }

    /// The in-flight request's result is discarded once superseded, so its work has to be
    /// folded into the follow-up alongside every request queued behind it.
    func testSupersededInFlightRequestIsCombinedWithEveryQueuedFollowUp() async {
        let gate = AsyncGate()
        let performed = ValueLog<Int>()
        let coordinator = RefreshCoordinator<Int, Int>(
            coalesce: { current, next in current + next },
            perform: { request in
                await performed.append(request)
                if await performed.values == [1] {
                    await gate.wait()
                }
                return request
            }
        )

        let first = Task { await coordinator.submit(1) }
        await gate.waitUntilEntered()
        let second = Task { await coordinator.submit(2) }
        await coordinator.waitUntilWaiterCount(2)
        let third = Task { await coordinator.submit(4) }
        await coordinator.waitUntilWaiterCount(3)
        await gate.open()

        let values = await (first.value, second.value, third.value)
        let performedValues = await performed.values
        XCTAssertEqual(values.0, 7)
        XCTAssertEqual(values.1, 7)
        XCTAssertEqual(values.2, 7)
        XCTAssertEqual(
            performedValues,
            [1, 7],
            "the follow-up must carry the superseded in-flight request (1) as well as 2 and 4"
        )
    }

    func testSequentialRequestsEachRun() async {
        let performed = ValueLog<Int>()
        let coordinator = RefreshCoordinator<Int, Int>(
            coalesce: { _, next in next },
            perform: { request in
                await performed.append(request)
                return request
            }
        )

        let first = await coordinator.submit(1)
        let second = await coordinator.submit(2)
        let performedValues = await performed.values
        let running = await coordinator.isRunning
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(performedValues, [1, 2])
        XCTAssertFalse(running)
    }

    func testChangeDuringDiscoveryQueuesFollowUp() async {
        let gate = AsyncGate()
        let performed = ValueLog<String>()
        let configuration = ScanConfiguration(
            roots: ["/tmp"],
            maximumDepth: 3,
            includeLinkedWorktrees: true,
            ignoredDirectoryNames: []
        )
        let coordinator = RefreshCoordinator<RepositoryRefreshRequest, String>(
            coalesce: { $0.coalescing($1) },
            covers: { $0.covers($1) },
            perform: { request in
                let label = request.scope.isDiscovery ? "discovery" : "status"
                await performed.append(label)
                if request.scope.isDiscovery {
                    await gate.wait()
                }
                return label
            }
        )

        let first = Task {
            await coordinator.submit(
                RepositoryRefreshRequest(configuration: configuration, scope: .discovery)
            )
        }
        await gate.waitUntilEntered()
        let second = Task {
            await coordinator.submit(
                RepositoryRefreshRequest(configuration: configuration, scope: .status())
            )
        }
        await coordinator.waitUntilWaiterCount(2)
        await gate.open()

        let values = await (first.value, second.value)
        let performedValues = await performed.values
        XCTAssertEqual(values.0, "discovery")
        XCTAssertEqual(values.1, "discovery")
        XCTAssertEqual(performedValues, ["discovery", "discovery"])
    }

    func testSupersededInFlightRequestIsRequeuedWhenNoFollowUpIsPending() async {
        let gate = AsyncGate()
        let performed = ValueLog<Set<String>>()
        let coordinator = RefreshCoordinator<Set<String>, Set<String>>(
            coalesce: { current, next in current.union(next) },
            perform: { request in
                await performed.append(request)
                if request == ["alpha"] {
                    await gate.wait()
                }
                return request
            }
        )

        let first = Task { await coordinator.submit(["alpha"]) }
        await gate.waitUntilEntered()
        // "alpha" is in flight and uncovered, so its work must survive into the follow-up
        // rather than being discarded along with its superseded result.
        let second = Task { await coordinator.submit(["beta"]) }
        await coordinator.waitUntilWaiterCount(2)
        await gate.open()

        let values = await (first.value, second.value)
        let performedValues = await performed.values
        XCTAssertEqual(values.0, ["alpha", "beta"])
        XCTAssertEqual(values.1, ["alpha", "beta"])
        XCTAssertEqual(performedValues, [["alpha"], ["alpha", "beta"]])
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var didEnter = false
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        didEnter = true
        for waiter in enterWaiters {
            waiter.resume()
        }
        enterWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in holdWaiters {
            waiter.resume()
        }
        holdWaiters.removeAll()
    }
}

private actor ValueLog<Value: Sendable> {
    private(set) var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }
}
