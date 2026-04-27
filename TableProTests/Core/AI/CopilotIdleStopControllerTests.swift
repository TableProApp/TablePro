//
//  CopilotIdleStopControllerTests.swift
//  TableProTests
//
//  Verifies the deferred-stop state machine extracted from CopilotService.
//

@testable import TablePro
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

@Suite("CopilotIdleStopController")
@MainActor
struct CopilotIdleStopControllerTests {
    private static let timeout: Duration = .milliseconds(40)
    private static let waitPastTimeout: Duration = .milliseconds(120)
    private static let waitMidTimeout: Duration = .milliseconds(15)

    private func makeController(state: TestState) -> CopilotIdleStopController {
        CopilotIdleStopController(
            timeout: Self.timeout,
            isAuthenticated: { state.authenticated },
            isRunning: { state.running },
            onStopRequest: { state.stopCount += 1 }
        )
    }

    @Test("Stops when timer fires while unauthenticated and running")
    func stopsAfterTimeout() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        controller.schedule()
        try await Task.sleep(for: Self.waitPastTimeout)

        #expect(state.stopCount == 1)
    }

    @Test("Skips when already authenticated at schedule time")
    func skipsWhenAuthenticated() async throws {
        let state = TestState(authenticated: true)
        let controller = makeController(state: state)

        controller.schedule()
        try await Task.sleep(for: Self.waitPastTimeout)

        #expect(state.stopCount == 0)
    }

    @Test("Skips when authenticated by fire time")
    func skipsWhenAuthenticatedByFireTime() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        controller.schedule()
        try await Task.sleep(for: Self.waitMidTimeout)
        state.authenticated = true
        try await Task.sleep(for: Self.waitPastTimeout)

        #expect(state.stopCount == 0)
    }

    @Test("Skips when not running by fire time")
    func skipsWhenNotRunningByFireTime() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        controller.schedule()
        state.running = false
        try await Task.sleep(for: Self.waitPastTimeout)

        #expect(state.stopCount == 0)
    }

    @Test("Cancel before fire prevents stop")
    func cancelPreventsStop() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        controller.schedule()
        try await Task.sleep(for: Self.waitMidTimeout)
        controller.cancel()
        try await Task.sleep(for: Self.waitPastTimeout)

        #expect(state.stopCount == 0)
    }

    @Test("Reschedule cancels prior timer; only fires once")
    func rescheduleFiresOnce() async throws {
        let state = TestState()
        let controller = makeController(state: state)

        controller.schedule()
        try await Task.sleep(for: Self.waitMidTimeout)
        controller.schedule()
        try await Task.sleep(for: Self.waitPastTimeout)

        #expect(state.stopCount == 1)
    }
}
