//
//  AccountKeysModelTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct AccountKeysModelTests {
    private static let challenge = FakeAccountKeyFlows.failure(
        "sync.step_up_required",
        sync: .stepUp(acrValues: ["urn:tablepro:acr:passkey"], maxAgeSecs: 300)
    )

    private static func approved(_ fixture: AccountKeysFixture) {
        fixture.flows.state = .approved(av: 3, keyDevice: "key-this")
        fixture.flows.devices = [
            FakeAccountKeyFlows.device("key-mini", row: "row-mini", name: "Mac mini", compared: true, addedAtUs: 1),
            FakeAccountKeyFlows.device("key-this", row: "row-this", name: "MacBook Air", thisDevice: true, addedAtUs: 5),
        ]
        fixture.flows.requests = [FakeAccountKeyFlows.request("request-1")]
    }

    @Test("A Mac whose account has no keys offers setup and reads no devices")
    func noKeysReadsNoDevices() async {
        let fixture = AccountKeysFixture()
        let model = fixture.model()

        await model.reload()

        #expect(model.state.value == .noKeys)
        #expect(model.devices.value == nil)
        #expect(fixture.flows.calls(named: "accountDevices").isEmpty)
        model.setUpRecoveryKey()
        guard case .recoveryKey(let flow)? = model.sheet else {
            Issue.record("Set Up must open the recovery key sheet")
            return
        }
        #expect(flow.purpose == .setUp)
    }

    @Test("An approved Mac lists itself first, then its devices by when they joined, and the requests waiting")
    func approvedReadsDevicesAndRequests() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let model = fixture.model()

        await model.reload()

        #expect(model.isApproved)
        #expect(model.sortedDevices.map(\.keyDevice) == ["key-this", "key-mini"])
        #expect(model.requests.map(\.request) == ["request-1"])
    }

    @Test("A read that fails keeps what the page showed and says why")
    func failedReadKeepsState() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let model = fixture.model()
        await model.reload()
        fixture.flows.fail("keyState", with: FakeAccountKeyFlows.failure("sync.network"))

        await model.reload()

        #expect(model.isApproved)
        #expect(model.state.failure != nil)
        #expect(model.devices.value?.count == 2)
    }

    @Test("The core saying the keys changed reads the page again")
    func keyChangeReadsAgain() async throws {
        let fixture = AccountKeysFixture()
        let model = fixture.model()
        await model.reload()
        fixture.flows.state = .needsApproval(request: nil)

        fixture.keyChanges.send()

        try await waitUntil { model.state.value == .needsApproval(request: nil) }
        #expect(fixture.flows.calls(named: "keyState").count == 2)
    }

    // E2E F21: a device approved on another Mac stayed off this list until this Mac's next pass, reopening included.
    @Test("Opening the page runs a key pass and lists a device another Mac approved since this one's last pass")
    func openingRunsAKeyPass() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let approvedElsewhere = FakeAccountKeyFlows.device("key-air", row: "row-air", name: "MacBook Air 2", addedAtUs: 9)
        fixture.flows.onSyncKeys = { [flows = fixture.flows] in flows.devices.append(approvedElsewhere) }
        let model = fixture.model()

        await model.refresh()

        #expect(fixture.flows.calls(named: "syncKeysNow").count == 1)
        #expect(model.sortedDevices.map(\.keyDevice) == ["key-this", "key-mini", "key-air"])
    }

    @Test("Opening the page offline lists what this Mac holds and keeps it when the pass fails")
    func openingOfflineKeepsTheList() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        fixture.flows.fail("syncKeysNow", with: FakeAccountKeyFlows.failure("sync.network"))
        let model = fixture.model()

        await model.refresh()

        #expect(model.sortedDevices.map(\.keyDevice) == ["key-this", "key-mini"])
        #expect(model.devices.failure == nil)
        #expect(fixture.flows.calls(named: "accountDevices").count == 1)
    }

    @Test("A device another Mac approves while the page is open joins the list when the core says the keys changed")
    func rosterChangeWhileOpen() async throws {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let model = fixture.model()
        await model.refresh()
        fixture.flows.devices.append(FakeAccountKeyFlows.device("key-air", row: "row-air", name: "MacBook Air 2", addedAtUs: 9))

        fixture.keyChanges.send()

        try await waitUntil { model.sortedDevices.count == 3 }
        #expect(model.sortedDevices.last?.keyDevice == "key-air")
        #expect(fixture.flows.calls(named: "syncKeysNow").count == 1)
    }

    @Test("The reset rows read the page's service, and again when the keys or the account change")
    func resetRowsFollowThePage() async throws {
        let fixture = AccountKeysFixture()
        let model = fixture.model()
        fixture.resets.update { $0.pending = ResetKeysFixtures.pending(mine: false) }

        await model.resets.load()
        #expect(model.resets.pending?.reset == "reset-1")

        fixture.resets.update { $0.pending = nil }
        fixture.keyChanges.send()
        try await waitUntil { model.resets.pending == nil }

        fixture.resets.update { $0.keyState = .locked(cause: .leftOutOfRotation) }
        fixture.accountChanges.send()
        try await waitUntil { model.resets.offeredKind == .startEmpty }
    }

    @Test("A sign-in or sign-out forgets the account's keys, devices and requests and closes its sheet")
    func accountChangeForgetsState() async throws {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let model = fixture.model()
        await model.reload()
        model.replaceRecoveryKey()
        for _ in 0 ..< 3 {
            fixture.flows.fail("keyState", with: FakeAccountKeyFlows.failure("sync.network"))
        }

        fixture.accountChanges.send()

        // The reads after the change fail, so only the change itself can have dropped the old account's keys.
        try await waitUntil { model.state.failure != nil && fixture.flows.calls(named: "keyState").count >= 2 }
        #expect(model.sheet == nil)
        #expect(model.state.value == nil)
        #expect(model.devices.value == nil)
        #expect(model.requests.isEmpty)
    }

    @Test("Removing a device steps up once on the server's challenge, removes its row, then asks for the recovery key")
    func removeStepsUpThenRemovesTheRow() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        fixture.flows.fail("removeDeviceRow", with: Self.challenge)
        let model = fixture.model()
        await model.reload()
        let mini = fixture.flows.devices[0]

        await model.remove(mini)

        #expect(fixture.stepUps == [StepUpChallenge(acrValues: ["urn:tablepro:acr:passkey"], maxAgeSecs: 300)])
        let removal = FakeAccountKeyFlows.Call("removeDeviceRow", ["row-mini"])
        #expect(fixture.flows.calls(named: "removeDeviceRow") == [removal, removal])
        guard case .removal(let flow)? = model.sheet else {
            Issue.record("A removed row must ask for the recovery key")
            return
        }
        #expect(flow.lost.keyDevice == "key-mini")
        #expect(model.removing == nil)
    }

    @Test("A step-up the person closed removes nothing and says nothing")
    func canceledStepUpStops() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        fixture.flows.fail("removeDeviceRow", with: Self.challenge)
        fixture.stepUpFailure = AccountError.canceled
        let model = fixture.model()
        await model.reload()

        await model.remove(fixture.flows.devices[0])

        #expect(fixture.flows.calls(named: "removeDeviceRow").count == 1)
        #expect(model.sheet == nil)
        #expect(model.actionFailure == nil)
    }

    @Test("A refused removal says why and opens no sheet")
    func refusedRemovalSaysWhy() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        fixture.flows.fail("removeDeviceRow", with: FakeAccountKeyFlows.failure("sync.device_not_approved"))
        let model = fixture.model()
        await model.reload()

        await model.remove(fixture.flows.devices[0])

        #expect(model.sheet == nil)
        #expect(model.actionFailure?.title.contains("Mac mini") == true)
        #expect(fixture.stepUps.isEmpty)
    }

    @Test("A removal that ends after the account changed shows nothing of the old account")
    func removalAfterAccountChangeLandsNowhere() async throws {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let gate = AsyncGate()
        fixture.flows.removeRowGate = gate
        let model = fixture.model()
        await model.reload()

        let removal = Task { await model.remove(fixture.flows.devices[0]) }
        await gate.arrived(1)
        fixture.accountChanges.send()
        try await waitUntil { fixture.flows.calls(named: "keyState").count >= 2 }
        await gate.open()
        await removal.value

        #expect(model.sheet == nil)
        #expect(model.actionFailure == nil)
    }

    @Test("A device whose row is already gone goes straight to the recovery key")
    func rowlessDeviceSkipsTheRow() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let removed = FakeAccountKeyFlows.device("key-old", name: "Old Mac")
        let model = fixture.model()

        await model.remove(removed)

        #expect(fixture.flows.calls(named: "removeDeviceRow").isEmpty)
        guard case .removal(let flow)? = model.sheet else {
            Issue.record("A rowless device must ask for the recovery key")
            return
        }
        #expect(flow.lost.keyDevice == "key-old")
    }

    @Test("Asking for approval picks up the request this Mac already has open")
    func askPicksUpTheOpenRequest() async {
        let fixture = AccountKeysFixture()
        fixture.flows.state = .needsApproval(request: "request-open")
        let model = fixture.model()
        await model.reload()

        model.askForApproval()

        guard case .approval(let flow)? = model.sheet else {
            Issue.record("Ask must open the approval sheet")
            return
        }
        #expect(flow.request == "request-open")
        model.askAgain()
        guard case .approval(let again)? = model.sheet else {
            Issue.record("Ask Again must open a new approval sheet")
            return
        }
        #expect(again.request == nil)
        #expect(again.id != flow.id)
    }

    @Test("Closing a running approval cancels its session and reads the page again")
    func closingCancelsTheSession() async throws {
        let fixture = AccountKeysFixture()
        fixture.flows.state = .needsApproval(request: nil)
        let model = fixture.model()
        await model.reload()
        model.askForApproval()
        guard case .approval(let flow)? = model.sheet else {
            Issue.record("Ask must open the approval sheet")
            return
        }
        await flow.start()

        model.closeSheet()

        #expect(model.sheet == nil)
        try await waitUntil { !fixture.flows.calls(named: "cancelApprovalSession").isEmpty }
        #expect(fixture.flows.calls(named: "cancelApprovalSession") == [FakeAccountKeyFlows.Call("cancelApprovalSession", ["request-new"])])
        try await waitUntil { fixture.flows.calls(named: "keyState").count == 2 }
    }

    @Test("Each lock names its cause and offers only the ways back it leaves")
    func lockedStatesOfferTheirWayBack() {
        let causes: [LockCauseTag] = [.deviceRemoved, .leftOutOfRotation, .ownAccountReset, .accountEnded, .unanchored, .personalStopped]

        #expect(Set(causes.map(AccountKeysText.lockTitle)).count == causes.count)
        #expect(!AccountKeysText.canAskForApproval(.deviceRemoved))
        #expect(!AccountKeysText.canRecover(.deviceRemoved))
        #expect(!AccountKeysText.canAskForApproval(.accountEnded))
        #expect(AccountKeysText.canAskForApproval(.ownAccountReset))
        #expect(!AccountKeysText.canRecover(.ownAccountReset))
        #expect(AccountKeysText.canRecover(.leftOutOfRotation))
    }

    @Test("A refusal reads by its code, and the server's change code where it gave one")
    func errorsReadByCode() {
        #expect(AccountKeysText.message(for: FakeAccountKeyFlows.failure("sync.typed_back_wrong")).contains("groups"))
        #expect(AccountKeysText.message(for: FakeAccountKeyFlows.failure("keys.recovery_key")).contains("recovery key"))
        let taken = FakeAccountKeyFlows.failure("sync.rejected", sync: .rejected(code: "create_only"))
        #expect(AccountKeysText.message(for: taken) != AccountKeysText.message(for: FakeAccountKeyFlows.failure("sync.rejected")))
        #expect(AccountKeysText.message(for: FakeAccountKeyFlows.failure("sync.surprise")).contains("sync.surprise"))
    }
}
