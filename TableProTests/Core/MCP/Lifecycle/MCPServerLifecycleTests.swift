import Foundation
@testable import TablePro
import XCTest

final class MCPPortAllocatorTests: XCTestCase {
    func testPrefersTheConfiguredPortAndFallsBackToTheKernel() {
        XCTAssertEqual(MCPPortAllocator.candidates(preferred: 23_508), [23_508, 0])
        XCTAssertEqual(MCPPortAllocator.candidates(preferred: 1), [1, 0])
        XCTAssertEqual(MCPPortAllocator.candidates(preferred: 65_535), [65_535, 0])
    }

    func testAPortOutsideTheValidRangeLeavesOnlyTheKernelAssignedOne() {
        XCTAssertEqual(MCPPortAllocator.candidates(preferred: 0), [0])
        XCTAssertEqual(MCPPortAllocator.candidates(preferred: -1), [0])
        XCTAssertEqual(MCPPortAllocator.candidates(preferred: 70_000), [0])
    }

    func testTheKernelAssignedCandidateIsAlwaysLast() {
        for preferred in [-1, 0, 1, 23_508, 65_535, 70_000] {
            XCTAssertEqual(MCPPortAllocator.candidates(preferred: preferred).last, MCPPortAllocator.kernelAssigned)
        }
    }

    func testEveryCandidateRejectedReportsTheLastFailure() {
        let error = MCPPortAllocatorError.everyCandidateRejected(lastFailure: "address in use")
        XCTAssertEqual(error.errorDescription?.contains("address in use"), true)
    }
}

@MainActor
final class MCPServerLifecycleQueueTests: XCTestCase {
    func testWorkRunsInTheOrderItWasEnqueued() async {
        let queue = MCPServerLifecycleQueue()
        let recorder = OrderRecorder()

        queue.enqueue { await recorder.append("first", after: .milliseconds(20)) }
        queue.enqueue { await recorder.append("second", after: .zero) }
        await queue.run { await recorder.append("third", after: .zero) }

        let entries = await recorder.entries
        XCTAssertEqual(entries, ["first", "second", "third"])
    }

    func testRunOnlyReturnsOnceItsWorkFinished() async {
        let queue = MCPServerLifecycleQueue()
        let recorder = OrderRecorder()

        await queue.run { await recorder.append("done", after: .milliseconds(20)) }

        let entries = await recorder.entries
        XCTAssertEqual(entries, ["done"])
    }

    func testEnqueuedWorkNeverOverlaps() async {
        let queue = MCPServerLifecycleQueue()
        let probe = OverlapProbe()

        for index in 0 ..< 8 {
            queue.enqueue { await probe.run("step-\(index)", holdingFor: .milliseconds(5)) }
        }
        await queue.drain()

        let peak = await probe.peakConcurrency
        let completed = await probe.completed
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(completed, (0 ..< 8).map { "step-\($0)" })
    }

    func testAnInterleavedStartAndStopNeverOrphansAListener() async {
        let queue = MCPServerLifecycleQueue()
        let listener = ListenerModel()

        for _ in 0 ..< 4 {
            queue.enqueue { await listener.start() }
            queue.enqueue { await listener.stop() }
        }
        await queue.drain()

        let overlaps = await listener.overlaps
        let transitions = await listener.transitions
        let running = await listener.isRunning
        XCTAssertEqual(overlaps, 0)
        XCTAssertEqual(transitions, ["start", "stop", "start", "stop", "start", "stop", "start", "stop"])
        XCTAssertFalse(running)
    }

    func testAwaitingOneEnqueuedTaskWaitsForEverythingBeforeIt() async {
        let queue = MCPServerLifecycleQueue()
        let recorder = OrderRecorder()

        queue.enqueue { await recorder.append("slow", after: .milliseconds(30)) }
        let last = queue.enqueue { await recorder.append("last", after: .zero) }
        await last.value

        let entries = await recorder.entries
        XCTAssertEqual(entries, ["slow", "last"])
    }

    func testDrainingAnEmptyQueueReturnsImmediately() async {
        let queue = MCPServerLifecycleQueue()

        await queue.drain()

        let recorder = OrderRecorder()
        await queue.run { await recorder.append("after-drain", after: .zero) }
        let entries = await recorder.entries
        XCTAssertEqual(entries, ["after-drain"])
    }

    func testDrainWaitsForEveryScheduledPiece() async {
        let queue = MCPServerLifecycleQueue()
        let recorder = OrderRecorder()

        queue.enqueue { await recorder.append("one", after: .milliseconds(20)) }
        queue.enqueue { await recorder.append("two", after: .milliseconds(20)) }
        queue.enqueue { await recorder.append("three", after: .milliseconds(20)) }
        await queue.drain()

        let entries = await recorder.entries
        XCTAssertEqual(entries, ["one", "two", "three"])
    }
}

@MainActor
final class MCPServerManagerIdleStateTests: XCTestCase {
    func testStoppingAServerThatNeverStartedLeavesNothingBehind() async {
        let manager = MCPServerManager.shared

        await manager.stop()

        XCTAssertEqual(manager.state, .stopped)
        XCTAssertFalse(manager.isRunning)
        XCTAssertNil(manager.listeningPort)
        XCTAssertNil(manager.tokenStore)
        XCTAssertTrue(manager.connectedClients.isEmpty)
    }

    func testStoppingTwiceIsIdempotent() async {
        let manager = MCPServerManager.shared

        await manager.stop()
        await manager.stop()

        XCTAssertEqual(manager.state, .stopped)
        XCTAssertNil(manager.tokenStore)
    }

    func testServerStatesAreDistinguishable() {
        XCTAssertNotEqual(MCPServerState.stopped, .starting)
        XCTAssertNotEqual(MCPServerState.running(port: 1), .running(port: 2))
        XCTAssertEqual(MCPServerState.failed("boom"), .failed("boom"))
    }
}

final class MCPServerInstanceIdentityTests: XCTestCase {
    func testBeginIssuesAFreshIdentityAndEndClearsIt() {
        let identity = MCPServerInstanceIdentity.shared

        let first = identity.begin()
        let second = identity.begin()

        XCTAssertFalse(first.isEmpty)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(identity.current, second)

        identity.end()
        XCTAssertTrue(identity.current.isEmpty)
    }

    func testTheInstanceIdMetaKeyIsNamespacedToTablePro() {
        XCTAssertEqual(MCPServerInstanceIdentity.metaKey, "app.tablepro/instanceId")
        XCTAssertTrue(MCPMetaKeys.isValid(key: MCPServerInstanceIdentity.metaKey))
        XCTAssertFalse(MCPMetaKeys.isReserved(key: MCPServerInstanceIdentity.metaKey))
    }
}

private actor OrderRecorder {
    private(set) var entries: [String] = []

    func append(_ entry: String, after delay: Duration) async {
        if delay != .zero {
            try? await Task.sleep(for: delay)
        }
        entries.append(entry)
    }
}

private actor OverlapProbe {
    private var active = 0
    private(set) var peakConcurrency = 0
    private(set) var completed: [String] = []

    func run(_ name: String, holdingFor duration: Duration) async {
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        try? await Task.sleep(for: duration)
        active -= 1
        completed.append(name)
    }
}

private actor ListenerModel {
    private var inFlight = 0

    private(set) var isRunning = false
    private(set) var overlaps = 0
    private(set) var transitions: [String] = []

    func start() async {
        beginStep()
        try? await Task.sleep(for: .milliseconds(5))
        isRunning = true
        endStep("start")
    }

    func stop() async {
        beginStep()
        try? await Task.sleep(for: .milliseconds(5))
        isRunning = false
        endStep("stop")
    }

    private func beginStep() {
        if inFlight > 0 {
            overlaps += 1
        }
        inFlight += 1
    }

    private func endStep(_ name: String) {
        transitions.append(name)
        inFlight -= 1
    }
}
