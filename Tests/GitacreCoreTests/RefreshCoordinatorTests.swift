import XCTest
@testable import GitacreCore

final class RefreshCoordinatorTests: XCTestCase {
    func testOverlappingRequestsCoalesceIntoOneFollowUpAndDiscardStaleResults() async {
        let gate = AsyncGate()
        let performed = ValueLog<Int>()
        let coordinator = RefreshCoordinator<Int, Int>(
            coalesce: { _, next in next },
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
        let third = Task { await coordinator.submit(3) }
        await coordinator.waitUntilWaiterCount(3)
        await gate.open()

        let values = await (first.value, second.value, third.value)
        let performedValues = await performed.values
        XCTAssertEqual(values.0, 30)
        XCTAssertEqual(values.1, 30)
        XCTAssertEqual(values.2, 30)
        XCTAssertEqual(performedValues, [1, 3])
    }

    func testCoalesceCombinesPendingRequestsRatherThanTheInFlightOne() async {
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
        let third = Task { await coordinator.submit(4) }
        await coordinator.waitUntilWaiterCount(3)
        await gate.open()

        let values = await (first.value, second.value, third.value)
        let performedValues = await performed.values
        XCTAssertEqual(values.0, 6)
        XCTAssertEqual(values.1, 6)
        XCTAssertEqual(values.2, 6)
        XCTAssertEqual(performedValues, [1, 6])
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

    func testInFlightDiscoveryCoversAStatusRefreshWithTheSameConfiguration() async {
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
        XCTAssertEqual(performedValues, ["discovery"])
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
