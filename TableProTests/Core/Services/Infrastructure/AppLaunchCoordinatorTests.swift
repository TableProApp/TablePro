import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct AppLaunchCoordinatorTests {
    private let environment = RecordingLaunchEnvironment()
    private let coordinator: AppLaunchCoordinator

    init() {
        coordinator = AppLaunchCoordinator(environment: environment)
    }

    @Test
    func nothingIsRoutedBeforeTheFirstTurn() {
        let connectionId = UUID()
        coordinator.deliver([.openConnection(connectionId)])
        coordinator.didFinishLaunching()

        #expect(coordinator.phase == .collectingIntents)
        #expect(environment.routedConnectionIds.isEmpty)
        #expect(environment.pendingTurnCount == 1)
    }

    /// The gesture that launched the app reaches `application(_:open:)` before
    /// `applicationDidFinishLaunching`, so this is the ordinary case, not an edge one.
    @Test
    func anIntentDeliveredBeforeLaunchFinishesIsRoutedOnce() async throws {
        let connectionId = UUID()
        coordinator.deliver([.openConnection(connectionId)])
        coordinator.didFinishLaunching()

        try await environment.runNextTurnAndWaitForCompletion()

        #expect(environment.routedConnectionIds == [connectionId])
        #expect(coordinator.phase == .ready)
    }

    /// A straggler from the same gesture lands within a few milliseconds of
    /// `applicationDidFinishLaunching` and before the first turn of the main queue, so it must join
    /// the same routing pass rather than opening a second window behind the first.
    @Test
    func anIntentDeliveredAfterLaunchFinishesJoinsTheSamePass() async throws {
        let first = UUID()
        let second = UUID()
        coordinator.deliver([.openConnection(first)])
        coordinator.didFinishLaunching()
        coordinator.deliver([.openConnection(second)])

        try await environment.runNextTurnAndWaitForCompletion()

        #expect(environment.routedConnectionIds == [first, second])
        #expect(environment.startupBehaviorRuns == 1)
        #expect(environment.completions == 1)
    }

    @Test
    func everyIntentInOneDeliveryIsRoutedInOrder() async throws {
        let ids = [UUID(), UUID(), UUID()]
        coordinator.deliver(ids.map { .openConnection($0) })
        coordinator.didFinishLaunching()

        try await environment.runNextTurnAndWaitForCompletion()

        #expect(environment.routedConnectionIds == ids)
    }

    @Test
    func aLaunchWithNoIntentsStillRunsTheStartupBehaviour() async throws {
        coordinator.didFinishLaunching()

        try await environment.runNextTurnAndWaitForCompletion()

        #expect(environment.routedConnectionIds.isEmpty)
        #expect(environment.startupBehaviorRuns == 1)
        #expect(environment.welcomeFallbackRuns == 1)
        #expect(coordinator.phase == .ready)
    }

    /// A second scheduled turn would route the same intents twice. Nothing schedules one today, and
    /// this is what keeps that true.
    @Test
    func aSecondTurnRoutesNothingFurther() async throws {
        let connectionId = UUID()
        coordinator.deliver([.openConnection(connectionId)])
        coordinator.didFinishLaunching()
        try await environment.runNextTurnAndWaitForCompletion()

        environment.replayLastTurn()
        await environment.runQueuedMainActorWork()

        #expect(environment.routedConnectionIds == [connectionId])
        #expect(environment.completions == 1)
    }

    @Test
    func anIntentArrivingAfterReadyIsRoutedOnItsOwn() async throws {
        coordinator.didFinishLaunching()
        try await environment.runNextTurnAndWaitForCompletion()

        let late = UUID()
        coordinator.deliver([.openConnection(late)])
        try await waitUntil { environment.dismissWelcomeRuns == 2 }

        #expect(environment.routedConnectionIds == [late])
        #expect(environment.dismissWelcomeRuns == 2)
    }

    /// Routing suspends: `TabRouter.openTable` awaits `ensureConnected`. An intent that arrives
    /// during that wait must join the pass in flight, not start a second one, or two tasks can each
    /// find no session for the same connection and each open one.
    @Test
    func anIntentArrivingDuringARouteJoinsTheSameDrain() async throws {
        let first = UUID()
        let second = UUID()
        environment.holdsRoutes = true
        coordinator.deliver([.openConnection(first)])
        coordinator.didFinishLaunching()
        environment.fireNextTurn()
        try await waitUntil { environment.isHoldingARoute }

        #expect(environment.routedConnectionIds == [first], "The first route should still be suspended")

        coordinator.deliver([.openConnection(second)])
        await environment.runQueuedMainActorWork()

        #expect(environment.routedConnectionIds == [first], "The second intent must wait, not race")
        #expect(environment.concurrentRoutes == 1)

        environment.holdsRoutes = false
        environment.releaseRoute()
        try await waitUntil { environment.completions == 1 }

        #expect(environment.routedConnectionIds == [first, second])
        #expect(environment.concurrentRoutes == 1, "Only one route may be in flight at a time")
        #expect(environment.completions == 1)
    }

    @Test
    func startupBehaviourIsToldWhetherAnyIntentWasRouted() async throws {
        coordinator.deliver([.openConnection(UUID())])
        coordinator.didFinishLaunching()

        try await environment.runNextTurnAndWaitForCompletion()

        #expect(environment.startupBehaviorSawIntents)
    }

    @Test
    func reopenWithNoVisibleWindowsPresentsWelcome() {
        let handled = coordinator.handleReopen(hasVisibleWindows: false)

        #expect(!handled)
        #expect(environment.presentWelcomeRuns == 1)
    }

    @Test
    func reopenWithVisibleWindowsPresentsNothing() {
        let handled = coordinator.handleReopen(hasVisibleWindows: true)

        #expect(handled)
        #expect(environment.presentWelcomeRuns == 0)
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
    var isHoldingARoute: Bool { routeGate != nil }

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
        guard !turns.isEmpty else {
            Issue.record("No turn was scheduled")
            return
        }
        turns.removeFirst()()
    }

    /// `launchDidComplete()` is the coordinator's own last step, so the count moving is the signal.
    func runNextTurnAndWaitForCompletion() async throws {
        guard !turns.isEmpty else {
            Issue.record("No turn was scheduled")
            return
        }
        let target = completions + 1
        turns.removeFirst()()
        try await waitUntil { self.completions >= target }
        #expect(completions == target, "The routing pass ran more than once")
    }

    /// The main queue runs its jobs in order, so a job queued now runs after every routing task the
    /// case has already started has reached its first suspension.
    func runQueuedMainActorWork() async {
        await Task { @MainActor in }.value
    }
}
