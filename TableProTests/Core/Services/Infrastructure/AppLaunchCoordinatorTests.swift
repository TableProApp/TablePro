//
//  AppLaunchCoordinatorTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

@MainActor
final class AppLaunchCoordinatorTests: XCTestCase {
    private var environment: RecordingLaunchEnvironment!
    private var coordinator: AppLaunchCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        environment = RecordingLaunchEnvironment()
        coordinator = AppLaunchCoordinator(environment: environment)
    }

    override func tearDown() async throws {
        coordinator = nil
        environment = nil
        try await super.tearDown()
    }

    func testNothingIsRoutedBeforeTheFirstTurn() async {
        let connectionId = UUID()
        coordinator.deliver([.openConnection(connectionId)])
        coordinator.didFinishLaunching()

        XCTAssertEqual(coordinator.phase, .collectingIntents)
        XCTAssertTrue(environment.routedConnectionIds.isEmpty)
        XCTAssertEqual(environment.pendingTurnCount, 1)
    }

    /// The gesture that launched the app reaches `application(_:open:)` before
    /// `applicationDidFinishLaunching`, so this is the ordinary case, not an edge one.
    func testAnIntentDeliveredBeforeLaunchFinishesIsRoutedOnce() async {
        let connectionId = UUID()
        coordinator.deliver([.openConnection(connectionId)])
        coordinator.didFinishLaunching()

        await environment.runNextTurnAndWaitForCompletion()

        XCTAssertEqual(environment.routedConnectionIds, [connectionId])
        XCTAssertEqual(coordinator.phase, .ready)
    }

    /// A straggler from the same gesture lands within a few milliseconds of
    /// `applicationDidFinishLaunching` and before the first turn of the main queue, so it must join
    /// the same routing pass rather than opening a second window behind the first.
    func testAnIntentDeliveredAfterLaunchFinishesJoinsTheSamePass() async {
        let first = UUID()
        let second = UUID()
        coordinator.deliver([.openConnection(first)])
        coordinator.didFinishLaunching()
        coordinator.deliver([.openConnection(second)])

        await environment.runNextTurnAndWaitForCompletion()

        XCTAssertEqual(environment.routedConnectionIds, [first, second])
        XCTAssertEqual(environment.startupBehaviorRuns, 1)
        XCTAssertEqual(environment.completions, 1)
    }

    func testEveryIntentInOneDeliveryIsRoutedInOrder() async {
        let ids = [UUID(), UUID(), UUID()]
        coordinator.deliver(ids.map { .openConnection($0) })
        coordinator.didFinishLaunching()

        await environment.runNextTurnAndWaitForCompletion()

        XCTAssertEqual(environment.routedConnectionIds, ids)
    }

    func testALaunchWithNoIntentsStillRunsTheStartupBehaviour() async {
        coordinator.didFinishLaunching()

        await environment.runNextTurnAndWaitForCompletion()

        XCTAssertTrue(environment.routedConnectionIds.isEmpty)
        XCTAssertEqual(environment.startupBehaviorRuns, 1)
        XCTAssertEqual(environment.welcomeFallbackRuns, 1)
        XCTAssertEqual(coordinator.phase, .ready)
    }

    /// A second scheduled turn would route the same intents twice. Nothing schedules one today, and
    /// this is what keeps that true.
    func testASecondTurnRoutesNothingFurther() async {
        let connectionId = UUID()
        coordinator.deliver([.openConnection(connectionId)])
        coordinator.didFinishLaunching()
        await environment.runNextTurnAndWaitForCompletion()

        environment.replayLastTurn()
        await environment.settle()

        XCTAssertEqual(environment.routedConnectionIds, [connectionId])
        XCTAssertEqual(environment.completions, 1)
    }

    func testAnIntentArrivingAfterReadyIsRoutedOnItsOwn() async {
        coordinator.didFinishLaunching()
        await environment.runNextTurnAndWaitForCompletion()

        let late = UUID()
        coordinator.deliver([.openConnection(late)])
        await environment.settle()

        XCTAssertEqual(environment.routedConnectionIds, [late])
        XCTAssertEqual(environment.dismissWelcomeRuns, 2)
    }

    /// Routing suspends: `TabRouter.openTable` awaits `ensureConnected`. An intent that arrives
    /// during that wait must join the pass in flight, not start a second one, or two tasks can each
    /// find no session for the same connection and each open one.
    func testAnIntentArrivingDuringARouteJoinsTheSameDrain() async {
        let first = UUID()
        let second = UUID()
        environment.holdsRoutes = true
        coordinator.deliver([.openConnection(first)])
        coordinator.didFinishLaunching()
        environment.fireNextTurn()
        await environment.settle()

        XCTAssertEqual(environment.routedConnectionIds, [first], "The first route should still be suspended")

        coordinator.deliver([.openConnection(second)])
        await environment.settle()

        XCTAssertEqual(environment.routedConnectionIds, [first], "The second intent must wait, not race")
        XCTAssertEqual(environment.concurrentRoutes, 1)

        environment.holdsRoutes = false
        environment.releaseRoute()
        await environment.settle()

        XCTAssertEqual(environment.routedConnectionIds, [first, second])
        XCTAssertEqual(environment.concurrentRoutes, 1, "Only one route may be in flight at a time")
        XCTAssertEqual(environment.completions, 1)
    }

    func testStartupBehaviourIsToldWhetherAnyIntentWasRouted() async {
        coordinator.deliver([.openConnection(UUID())])
        coordinator.didFinishLaunching()

        await environment.runNextTurnAndWaitForCompletion()

        XCTAssertTrue(environment.startupBehaviorSawIntents)
    }

    func testReopenWithNoVisibleWindowsPresentsWelcome() {
        let handled = coordinator.handleReopen(hasVisibleWindows: false)

        XCTAssertFalse(handled)
        XCTAssertEqual(environment.presentWelcomeRuns, 1)
    }

    func testReopenWithVisibleWindowsPresentsNothing() {
        let handled = coordinator.handleReopen(hasVisibleWindows: true)

        XCTAssertTrue(handled)
        XCTAssertEqual(environment.presentWelcomeRuns, 0)
    }
}

@MainActor
private final class RecordingLaunchEnvironment: LaunchEnvironment {
    private(set) var routedConnectionIds: [UUID] = []
    private(set) var closeWelcomeRuns = 0
    private(set) var dismissWelcomeRuns = 0
    private(set) var startupBehaviorRuns = 0
    private(set) var welcomeFallbackRuns = 0
    private(set) var presentWelcomeRuns = 0
    private(set) var completions = 0
    private(set) var startupBehaviorSawIntents = false
    private(set) var concurrentRoutes = 0

    /// Set to suspend `route` until `releaseRoute()` is called, which is how a launch that awaits
    /// `ensureConnected` behaves.
    var holdsRoutes = false
    private var routeGate: CheckedContinuation<Void, Never>?
    private var activeRoutes = 0

    private var turns: [@MainActor () -> Void] = []
    private var lastTurn: (@MainActor () -> Void)?

    var pendingTurnCount: Int { turns.count }

    func scheduleNextTurn(_ body: @escaping @MainActor () -> Void) {
        turns.append(body)
        lastTurn = body
    }

    func route(_ intent: LaunchIntent) async {
        activeRoutes += 1
        concurrentRoutes = max(concurrentRoutes, activeRoutes)
        if let connectionId = intent.targetConnectionId {
            routedConnectionIds.append(connectionId)
        }
        if holdsRoutes {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                routeGate = continuation
            }
        }
        activeRoutes -= 1
    }

    func releaseRoute() {
        let gate = routeGate
        routeGate = nil
        gate?.resume()
    }

    func closeWelcome() { closeWelcomeRuns += 1 }
    func dismissWelcomeIfMainWindowVisible() { dismissWelcomeRuns += 1 }
    func runStartupBehavior(hadIntents: Bool) {
        startupBehaviorRuns += 1
        startupBehaviorSawIntents = hadIntents
    }

    func presentWelcomeIfNoMainWindow(hadIntents: Bool) { welcomeFallbackRuns += 1 }
    func presentWelcome() { presentWelcomeRuns += 1 }
    func launchDidComplete() { completions += 1 }

    func replayLastTurn() {
        lastTurn?()
    }

    func fireNextTurn() {
        guard !turns.isEmpty else { return XCTFail("No turn was scheduled") }
        turns.removeFirst()()
    }

    /// Fires the turn the coordinator scheduled, then drains the main queue until the routing task
    /// it starts has finished. `launchDidComplete()` is the coordinator's own last step, so the
    /// count moving is the signal, not a sleep.
    func runNextTurnAndWaitForCompletion() async {
        guard !turns.isEmpty else { return XCTFail("No turn was scheduled") }
        let target = completions + 1
        turns.removeFirst()()
        for _ in 0 ..< 100 where completions < target {
            await Task.yield()
        }
        XCTAssertEqual(completions, target, "The routing pass never completed")
    }

    /// Lets any already-started task finish without expecting a completion.
    func settle() async {
        for _ in 0 ..< 100 {
            await Task.yield()
        }
    }
}
