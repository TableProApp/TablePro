//
//  AccountRemovalFlowTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import Testing

@MainActor
struct AccountRemovalFlowTests {
    private final class Opened {
        var urls: [URL] = []
    }

    private static let lost = FakeAccountKeyFlows.device("key-lost", row: nil, name: "Old MacBook")

    private static func member(_ team: String, _ account: String, teamID: String?, teamName: String, name: String) -> AccountRemovalReview.Member {
        AccountRemovalReview.Member(
            record: ReviewedMemberInfo(team: team, account: account, confirmedUnderAv: 2),
            teamID: teamID,
            teamName: teamName,
            name: name,
            email: "\(name.lowercased())@example.com"
        )
    }

    private static func review() -> AccountRemovalReview {
        AccountRemovalReview(
            review: "review-1",
            devices: [
                ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-this", thisDevice: true), keepByDefault: false),
                ReviewedDeviceInfo(device: lost, keepByDefault: false),
                ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-phone", compared: true), keepByDefault: true),
                ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-tablet"), keepByDefault: false),
            ],
            members: [
                member("team_a", "ACCT-1", teamID: "TEAM-A", teamName: "Acme", name: "Ana"),
                member("team_b", "ACCT-2", teamID: "TEAM-B", teamName: "Beta", name: "Bao"),
                member("team_a", "ACCT-3", teamID: "TEAM-A", teamName: "Acme", name: "Chi"),
            ]
        )
    }

    private static func flow(_ flows: FakeAccountKeyFlows, opened: Opened) -> AccountRemovalFlow {
        AccountRemovalFlow(
            lost: lost,
            flows: { flows },
            portal: { AccountPortal(server: .production) },
            openURL: { opened.urls.append($0) }
        )
    }

    @Test("The recovery key opens the review for the lost device, and the key is dropped once read")
    func keyOpensTheReview() async {
        let flows = FakeAccountKeyFlows()
        flows.review = Self.review()
        let flow = Self.flow(flows, opened: Opened())
        #expect(!flow.canContinue)
        flow.recoveryKey = FakeAccountKeyFlows.recoveryKey

        await flow.advance()

        #expect(flow.step == .review)
        #expect(flow.recoveryKey.isEmpty)
        #expect(flows.calls(named: "reviewDeviceRemoval") == [
            FakeAccountKeyFlows.Call("reviewDeviceRemoval", [FakeAccountKeyFlows.recoveryKey, "key-lost"])
        ])
        #expect(flow.keep == ["key-phone"])
        #expect(flow.memberGroups.map(\.team.name) == ["Acme", "Beta"])
        #expect(flow.memberGroups.first?.members.map(\.name) == ["Ana", "Chi"])
    }

    @Test("Only compared devices can be kept, never the lost one or this Mac")
    func keepRules() async {
        let flows = FakeAccountKeyFlows()
        let review = Self.review()
        flows.review = review
        let flow = Self.flow(flows, opened: Opened())
        flow.recoveryKey = "key"
        await flow.advance()

        flow.setKeep(review.devices[1], true)
        flow.setKeep(review.devices[3], true)
        flow.setKeep(review.devices[0], true)

        #expect(flow.keep == ["key-phone"])
        #expect(!flow.canKeep(review.devices[0]))
        #expect(!flow.canKeep(review.devices[1]))
        #expect(flow.canKeep(review.devices[2]))
    }

    @Test("Marked teammates send the person to their teams first, then Change Keys removes them and keeps the ticked devices")
    func seatsBeforeTheRotation() async throws {
        let flows = FakeAccountKeyFlows()
        let review = Self.review()
        flows.review = review
        let opened = Opened()
        let flow = Self.flow(flows, opened: opened)
        flow.recoveryKey = "key"
        await flow.advance()
        flow.setRemoving(review.members[1], true)

        await flow.advance()

        #expect(flow.step == .seats)
        #expect(flows.calls(named: "finishDeviceRemoval").isEmpty)
        #expect(flow.teamsToVisit.map(\.name) == ["Beta"])
        flow.openTeam(try #require(flow.teamsToVisit.first))
        #expect(opened.urls == [AccountPortal(server: .production).portalTeam("TEAM-B")])
        flow.setRemoving(review.members[0], true)
        #expect(flow.removing.count == 1)

        await flow.advance()

        #expect(flows.calls(named: "finishDeviceRemoval") == [
            FakeAccountKeyFlows.Call("finishDeviceRemoval", ["review-1", "key-phone", "team_b/ACCT-2"])
        ])
        #expect(flow.step == .done)
    }

    @Test("Back from the seats step changes the choice before anything rotates")
    func backFromSeats() async {
        let flows = FakeAccountKeyFlows()
        let review = Self.review()
        flows.review = review
        let flow = Self.flow(flows, opened: Opened())
        flow.recoveryKey = "key"
        await flow.advance()
        flow.setRemoving(review.members[1], true)
        await flow.advance()

        flow.backToReview()
        flow.setRemoving(review.members[1], false)
        await flow.advance()

        #expect(flow.step == .done)
        #expect(flows.calls(named: "finishDeviceRemoval").first?.arguments == ["review-1", "key-phone"])
    }

    @Test("With every teammate kept, the removal ends without the portal")
    func noSeatsToRemove() async {
        let flows = FakeAccountKeyFlows()
        flows.review = Self.review()
        let flow = Self.flow(flows, opened: Opened())
        flow.recoveryKey = "key"
        await flow.advance()

        await flow.advance()

        #expect(flow.step == .done)
        #expect(flows.calls(named: "finishDeviceRemoval").first?.arguments == ["review-1", "key-phone"])
    }

    @Test("A wrong recovery key stays on its field with the reason")
    func wrongKey() async {
        let flows = FakeAccountKeyFlows()
        flows.fail("reviewDeviceRemoval", with: FakeAccountKeyFlows.failure("keys.recovery_key"))
        let flow = Self.flow(flows, opened: Opened())
        flow.recoveryKey = "WRONG"

        await flow.advance()

        #expect(flow.step == .enterKey)
        #expect(flow.failure != nil)
    }

    @Test("Recovery with the key approves this Mac and drops the key")
    func recover() async {
        let flows = FakeAccountKeyFlows()
        let flow = AccountRecoverFlow { flows }
        flow.recoveryKey = FakeAccountKeyFlows.recoveryKey

        await flow.recover()

        #expect(flow.isDone)
        #expect(flow.recoveryKey.isEmpty)
        #expect(flows.calls(named: "recover") == [FakeAccountKeyFlows.Call("recover", [FakeAccountKeyFlows.recoveryKey])])
    }

    @Test("A recovery the core refused keeps the key typed and says why")
    func refusedRecovery() async {
        let flows = FakeAccountKeyFlows()
        flows.fail("recover", with: FakeAccountKeyFlows.failure("keys.recovery_key"))
        let flow = AccountRecoverFlow { flows }
        flow.recoveryKey = "WRONG"

        await flow.recover()

        #expect(!flow.isDone)
        #expect(flow.failure != nil)
        #expect(flow.recoveryKey == "WRONG")
    }
}
