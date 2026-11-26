//
//  AccountApprovalFlowTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
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

    @Test("The new Mac asks, polls until an approver's words arrive, and confirms them")
    func newDeviceComparesAndConfirms() async throws {
        let flows = FakeAccountKeyFlows()
        let clock = ManualClock()
        flows.sessionPhases = [.open, .chosen, .compare(words: Self.words), .confirmed]
        let flow = Self.newDevice(flows, clock: clock)

        await flow.start()
        #expect(flow.phase == .waiting)
        #expect(flow.request == "request-new")
        #expect(flow.expiresAt == flows.expiresAt)
        try await Self.poll(flows, clock)
        try await waitUntil { flow.phase == .chosen }
        try await Self.poll(flows, clock)
        try await waitUntil { flow.phase == .compare(words: Self.words) }

        flows.sessionPhases = [.approved]
        await flow.wordsMatch()

        #expect(flows.calls(named: "confirmApprovalSession") == [FakeAccountKeyFlows.Call("confirmApprovalSession", ["request-new"])])
        #expect(flow.phase == .approved)
        #expect(clock.pendingSleeperCount == 0)
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

    @Test("Words that differ cancel with a mismatch and stop polling")
    func wordsDiffer() async {
        let flows = FakeAccountKeyFlows()
        let clock = ManualClock()
        flows.sessionPhases = [.compare(words: Self.words)]
        let flow = Self.newDevice(flows, clock: clock)
        await flow.start()

        await flow.wordsDiffer()

        #expect(flow.phase == .cancelled(.mismatch))
        #expect(flows.calls(named: "approvalWordsDiffer").count == 1)
        flow.close()
        #expect(flows.calls(named: "cancelApprovalSession").isEmpty)
    }

    @Test("An expired session ends the sheet's polling")
    func expiryEnds() async throws {
        let flows = FakeAccountKeyFlows()
        let clock = ManualClock()
        flows.sessionPhases = [.open, .expired]
        let flow = Self.newDevice(flows, clock: clock)
        await flow.start()

        try await Self.poll(flows, clock)

        try await waitUntil { flow.phase == .expired }
        #expect(flow.phase.hasEnded)
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test("The approver reviews the request first and commits only on Approve")
    func approverChoosesOnApprove() async {
        let flows = FakeAccountKeyFlows()
        flows.sessionPhases = [.chosen]
        let request = FakeAccountKeyFlows.request("request-7", name: "Studio")
        let flow = AccountApprovalFlow(role: .approver(request), flows: { flows }, clock: ManualClock())

        await flow.start()
        #expect(flow.phase == .reviewing)
        #expect(flows.calls.isEmpty)

        await flow.approve()

        #expect(flows.calls(named: "chooseApprovalRequest") == [FakeAccountKeyFlows.Call("chooseApprovalRequest", ["request-7"])])
        #expect(flow.phase == .chosen)
        flow.close()
        #expect(flow.phase == .cancelled(.user))
    }

    @Test("Closing before Approve writes nothing")
    func approverClosesWhileReviewing() async throws {
        let flows = FakeAccountKeyFlows()
        let flow = AccountApprovalFlow(role: .approver(FakeAccountKeyFlows.request("request-8")), flows: { flows }, clock: ManualClock())

        flow.close()

        #expect(flow.phase == .reviewing)
        #expect(flows.calls.isEmpty)
    }

    @Test("Another approver holding the session ends this one")
    func takenElsewhere() async {
        let flows = FakeAccountKeyFlows()
        flows.sessionPhases = [.takenElsewhere]
        let flow = AccountApprovalFlow(role: .approver(FakeAccountKeyFlows.request("request-9")), flows: { flows }, clock: ManualClock())

        await flow.approve()

        #expect(flow.phase == .takenElsewhere)
        flow.close()
        #expect(flows.calls(named: "cancelApprovalSession").isEmpty)
    }

    @Test("A request that could not be written ends with the reason")
    func failedRequest() async {
        let flows = FakeAccountKeyFlows()
        flows.fail("requestApproval", with: FakeAccountKeyFlows.failure("sync.rejected", sync: .rejected(code: "request_pending")))
        let flow = Self.newDevice(flows, clock: ManualClock())

        await flow.start()

        guard case .failed = flow.phase else {
            Issue.record("A refused request must end the sheet, it is \(flow.phase)")
            return
        }
    }
}
