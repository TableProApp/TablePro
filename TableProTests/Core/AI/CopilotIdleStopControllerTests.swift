import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private final class TestState {
    var authenticated: Bool
    var running: Bool
    var stopCount: Int = 0

    init(authenticated: Bool = false, running: Bool = true) {
        self.authenticated = authenticated
        self.running = running
    }
}

@MainActor
struct CopilotIdleStopControllerTests {
    private static let timeout: Duration = .seconds(300)

    private let clock = ManualClock()

    private func makeController(state: TestState) -> CopilotIdleStopController {
        CopilotIdleStopController(
            timeout: Self.timeout,
            clock: clock,
            isAuthenticated: { state.authenticated },
            isRunning: { state.running },
            onStopRequest: { state.stopCount += 1 }
        )
    }

    @Test("Stops when timer fires while unauthenticated and running")
    func stopsAfterTimeout() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let timer = try #require(controller.schedule())
        await clock.waitUntilSleeping()
        clock.advance(by: Self.timeout - .milliseconds(1))

        #expect(clock.pendingSleeperCount == 1)
        #expect(state.stopCount == 0)

        clock.advance(by: .milliseconds(1))
        await timer.value

        #expect(state.stopCount == 1)
    }

    @Test("Skips when already authenticated at schedule time")
    func skipsWhenAuthenticated() {
        let state = TestState(authenticated: true)
        let controller = makeController(state: state)

        #expect(controller.schedule() == nil)
        #expect(clock.pendingSleeperCount == 0)
        #expect(state.stopCount == 0)
    }

    @Test("Skips when authenticated by fire time")
    func skipsWhenAuthenticatedByFireTime() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let timer = try #require(controller.schedule())
        await clock.waitUntilSleeping()
        state.authenticated = true
        clock.advance(by: Self.timeout)
        await timer.value

        #expect(state.stopCount == 0)
    }

    @Test("Skips when not running by fire time")
    func skipsWhenNotRunningByFireTime() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let timer = try #require(controller.schedule())
        state.running = false
        await clock.waitUntilSleeping()
        clock.advance(by: Self.timeout)
        await timer.value

        #expect(state.stopCount == 0)
    }

    @Test("Cancel before fire prevents stop")
    func cancelPreventsStop() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let timer = try #require(controller.schedule())
        await clock.waitUntilSleeping()
        controller.cancel()
        clock.advance(by: Self.timeout)
        await timer.value

        #expect(clock.pendingSleeperCount == 0)
        #expect(state.stopCount == 0)
    }

    @Test("Reschedule cancels prior timer; only fires once")
    func rescheduleFiresOnce() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        let first = try #require(controller.schedule())
        await clock.waitUntilSleeping()
        let second = try #require(controller.schedule())
        await first.value
        await clock.waitUntilSleeping()
        clock.advance(by: Self.timeout)
        await second.value

        #expect(state.stopCount == 1)
    }
}
