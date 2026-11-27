import Foundation
import TableProFFI
@testable import TableProMobile
import TableProTestSupport
import Testing

@MainActor
struct AccountRemovalFlowTests {
    private static let lost = FakeAccountKeyFlows.device("key-lost", name: "Old iPhone")

    private static func flow(_ flows: FakeAccountKeyFlows, opened: @escaping (URL) -> Void = { _ in }) -> AccountRemovalFlow {
        AccountRemovalFlow(
            lost: lost,
            flows: { flows },
            teamPage: { URL(string: "https://account.tablepro.app/teams/\($0)")! },
            openURL: opened
        )
    }

    private static func review(members: [ReviewedMemberInfo] = []) -> RemovalReviewInfo {
        RemovalReviewInfo(
            review: "review-1",
            devices: [
                ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-this", thisDevice: true), keepByDefault: false),
                ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-mac", compared: true), keepByDefault: true),
                ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-other"), keepByDefault: true),
            ],
            members: members
        )
    }

    @Test("The recovery key opens the review, which keeps compared devices and sends the rotation with no teammate removed")
    func reviewThenRotate() async {
        let flows = FakeAccountKeyFlows()
        flows.review = Self.review()
        let flow = Self.flow(flows)
        flow.recoveryKey = FakeAccountKeyFlows.recoveryKey

        await flow.advance()

        #expect(flow.step == .review)
        #expect(flow.recoveryKey.isEmpty)
        #expect(flow.keep == ["key-mac"])
        #expect(flows.calls(named: "beginDeviceRemoval") == [
            FakeAccountKeyFlows.Call("beginDeviceRemoval", [FakeAccountKeyFlows.recoveryKey, "key-lost"]),
        ])
        await flow.advance()

        #expect(flow.step == .done)
        #expect(flows.calls(named: "finishDeviceRemoval") == [FakeAccountKeyFlows.Call("finishDeviceRemoval", ["review-1", "key-mac"])])
    }

    @Test("A teammate turned off goes through the portal's seats first, then leaves the rotation")
    func removedTeammateVisitsTheSeats() async {
        let flows = FakeAccountKeyFlows()
        let alice = FakeAccountKeyFlows.member("team_a", "acct_alice", teamName: "Data", name: "Alice")
        let me = FakeAccountKeyFlows.member("team_a", "acct_me", teamName: "Data", name: "Me", isSelf: true)
        flows.review = Self.review(members: [alice, me])
        var opened: [URL] = []
        let flow = Self.flow(flows) { opened.append($0) }
        flow.recoveryKey = FakeAccountKeyFlows.recoveryKey
        await flow.advance()
        let members = flow.memberGroups.first?.members ?? []

        flow.setRemoving(members[1], true)
        flow.setRemoving(members[0], true)
        await flow.advance()

        #expect(flow.step == .seats)
        #expect(flow.teamsToVisit.map(\.id) == ["team_a"])
        flow.openTeam(flow.teamsToVisit[0])
        #expect(opened == [URL(string: "https://account.tablepro.app/teams/team_a")!])
        await flow.advance()
        #expect(flows.calls(named: "finishDeviceRemoval") == [
            FakeAccountKeyFlows.Call("finishDeviceRemoval", ["review-1", "key-mac", "team_a/acct_alice"]),
        ])
    }

    @Test("A rotation that failed asks for the recovery key again with the reason")
    func failedRotationAsksAgain() async {
        let flows = FakeAccountKeyFlows()
        flows.review = Self.review()
        flows.fail("finishDeviceRemoval", with: FakeAccountKeyFlows.failure("sync.network"))
        let flow = Self.flow(flows)
        flow.recoveryKey = FakeAccountKeyFlows.recoveryKey
        await flow.advance()

        await flow.advance()

        #expect(flow.step == .enterKey)
        #expect(flow.failure?.contains(AccountKeysText.message(code: "sync.network")) == true)
    }

    @Test("Closing before the rotation drops the review in the core")
    func discardDropsTheReview() async throws {
        let flows = FakeAccountKeyFlows()
        flows.review = Self.review()
        let flow = Self.flow(flows)
        flow.recoveryKey = FakeAccountKeyFlows.recoveryKey
        await flow.advance()

        flow.discard()

        try await waitUntil { !flows.calls(named: "discardKeyDraft").isEmpty }
        #expect(flows.calls(named: "discardKeyDraft") == [FakeAccountKeyFlows.Call("discardKeyDraft", ["review-1"])])
    }
}
