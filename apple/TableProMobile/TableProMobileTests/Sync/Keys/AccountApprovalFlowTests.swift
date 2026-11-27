import Foundation
import TableProFFI
@testable import TableProMobile
import TableProTestSupport
import Testing

@MainActor
struct AccountApprovalFlowTests {
    private static let words = ["amber", "canyon", "lilac", "orbit", "tundra"]

    private static func newDevice(_ flows: FakeAccountKeyFlows, clock: ManualClock, request: String? = nil) -> AccountApprovalFlow {
        AccountApprovalFlow(role: .newDevice, request: request, flows: { flows }, clock: clock)
    }

    // One poll: the flow sleeps on the clock, the clock passes the interval, the read lands.
    private static func poll(_ flows: FakeAccountKeyFlows, _ clock: ManualClock) async throws {
        let reads = flows.calls(named: "approvalSession").count
        await clock.waitUntilSleeping()
        clock.advance(by: AccountApprovalFlow.pollInterval)
        try await waitUntil { flows.calls(named: "approvalSession").count > reads }
    }

    @Test("The new device asks, polls until an approver's words arrive, confirms them, and stops polling once approved")
    func newDeviceComparesAndConfirms() async throws {
        let flows = FakeAccountKeyFlows()
        let clock = ManualClock()
        flows.sessionPhases = [.open, .chosen, .compare(words: Self.words)]
        let flow = Self.newDevice(flows, clock: clock)

        await flow.start()
        #expect(flow.phase == .waiting)
        #expect(flow.request == "request-new")
        try await Self.poll(flows, clock)
        try await waitUntil { flow.phase == .chosen }
        try await Self.poll(flows, clock)
        try await waitUntil { flow.phase == .compare(words: Self.words) }

        flows.sessionPhases = [.approved]
        await flow.wordsMatch()

        #expect(flows.calls(named: "confirmApprovalSession") == [FakeAccountKeyFlows.Call("confirmApprovalSession", ["request-new"])])
        #expect(flow.phase == .approved)
        try await waitUntil { clock.pendingSleeperCount == 0 }
    }

    @Test("An open request is picked up, not asked for again")
    func reusesTheOpenRequest() async {
        let flows = FakeAccountKeyFlows()
        let flow = Self.newDevice(flows, clock: ManualClock(), request: "request-open")

        await flow.start()

        #expect(flows.calls(named: "requestApproval").isEmpty)
        #expect(flow.request == "request-open")
        flow.close()
    }

    @Test("Words that differ cancel with a mismatch, and closing after that cancels nothing more")
    func wordsDiffer() async {
        let flows = FakeAccountKeyFlows()
        flows.sessionPhases = [.compare(words: Self.words)]
        let flow = Self.newDevice(flows, clock: ManualClock())
        await flow.start()

        await flow.wordsDiffer()

        #expect(flow.phase == .cancelled(.mismatch))
        flow.close()
        #expect(flows.calls(named: "cancelApprovalSession").isEmpty)
    }

    @Test("The approver reviews the request first and commits only on Approve; closing then cancels it")
    func approverChoosesOnApprove() async throws {
        let flows = FakeAccountKeyFlows()
        flows.sessionPhases = [.chosen]
        let flow = AccountApprovalFlow(role: .approver(FakeAccountKeyFlows.request("request-7")), flows: { flows }, clock: ManualClock())

        await flow.start()
        #expect(flow.phase == .reviewing)
        #expect(flows.calls.isEmpty)

        await flow.approve()

        #expect(flows.calls(named: "chooseApprovalRequest") == [FakeAccountKeyFlows.Call("chooseApprovalRequest", ["request-7"])])
        #expect(flow.phase == .chosen)
        flow.close()
        #expect(flow.phase == .cancelled(.user))
        try await waitUntil { !flows.calls(named: "cancelApprovalSession").isEmpty }
    }

    @Test("A request whose first read failed is still cancelled when the sheet closes")
    func failedReadStillCancels() async throws {
        let flows = FakeAccountKeyFlows()
        flows.fail("approvalSession", with: FakeAccountKeyFlows.failure("sync.network"))
        let flow = Self.newDevice(flows, clock: ManualClock())

        await flow.start()
        #expect(flow.phase == .failed(AccountKeysText.message(code: "sync.network")))

        flow.close()

        try await waitUntil { !flows.calls(named: "cancelApprovalSession").isEmpty }
        #expect(flows.calls(named: "cancelApprovalSession") == [FakeAccountKeyFlows.Call("cancelApprovalSession", ["request-new"])])
    }

    @Test("Once approved, a later answer never brings the words back")
    func endedSessionStaysEnded() async {
        let flows = FakeAccountKeyFlows()
        flows.sessionPhases = [.compare(words: Self.words)]
        let flow = Self.newDevice(flows, clock: ManualClock())
        await flow.start()
        flows.sessionPhases = [.approved]
        await flow.wordsMatch()
        flows.sessionPhases = [.compare(words: Self.words)]

        await flow.refresh()

        #expect(flow.phase == .approved)
    }
}
