import Combine
import Foundation
import TableProFFI
@testable import TableProMobile
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
            FakeAccountKeyFlows.device("key-mac", row: "row-mac", name: "MacBook Air", compared: true, addedAtUs: 1),
            FakeAccountKeyFlows.device("key-this", row: "row-this", name: "iPhone", thisDevice: true, addedAtUs: 5),
        ]
        fixture.flows.requests = [FakeAccountKeyFlows.request("request-1")]
    }

    @Test("A device whose account has no keys offers setup and reads no devices")
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

    @Test("An approved device lists itself first, then the others by when they joined, and the requests waiting")
    func approvedReadsDevicesAndRequests() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let model = fixture.model()

        await model.reload()

        #expect(model.isApproved)
        #expect(model.sortedDevices.map(\.keyDevice) == ["key-this", "key-mac"])
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
        #expect(model.state.failure == AccountKeysText.message(code: "sync.network"))
        #expect(model.devices.value?.count == 2)
    }

    @Test("A sign-in or sign-out forgets the account's keys, devices and requests and closes its sheet")
    func accountChangeForgets() async throws {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let model = fixture.model()
        await model.reload()
        model.replaceRecoveryKey()
        fixture.flows.state = .noKeys

        fixture.accountChanges.send()

        try await waitUntil { model.state.value == .noKeys }
        #expect(model.sheet == nil)
        #expect(model.devices.value == nil)
        #expect(model.requests.isEmpty)
    }

    @Test("Removing a device steps up once on the server's challenge, removes its row, then asks for the recovery key")
    func removeStepsUpThenAsksForTheKey() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        fixture.flows.fail("removeDeviceRow", with: Self.challenge)
        let model = fixture.model()
        await model.reload()

        await model.remove(fixture.flows.devices[0])

        #expect(fixture.stepUps == [StepUpChallenge(acrValues: ["urn:tablepro:acr:passkey"], maxAgeSecs: 300)])
        #expect(fixture.flows.calls(named: "removeDeviceRow").count == 2)
        guard case .removal(let flow)? = model.sheet else {
            Issue.record("A removed row must open the recovery key step")
            return
        }
        #expect(flow.lost.keyDevice == "key-mac")
        #expect(model.removing == nil)
    }

    @Test("A step-up the person closed removes nothing and says nothing")
    func cancelledStepUpSaysNothing() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        fixture.flows.fail("removeDeviceRow", with: Self.challenge)
        fixture.stepUpFailure = AccountError.canceled
        let model = fixture.model()
        await model.reload()

        await model.remove(fixture.flows.devices[0])

        #expect(model.sheet == nil)
        #expect(model.actionFailure == nil)
    }

    @Test("A device whose row is already gone goes straight to the recovery key")
    func rowlessDeviceSkipsTheStepUp() async {
        let fixture = AccountKeysFixture()
        Self.approved(fixture)
        let model = fixture.model()
        await model.reload()

        await model.remove(FakeAccountKeyFlows.device("key-gone"))

        #expect(fixture.flows.calls(named: "removeDeviceRow").isEmpty)
        #expect(fixture.stepUps.isEmpty)
        guard case .removal? = model.sheet else {
            Issue.record("A rowless device must open the recovery key step")
            return
        }
    }

    @Test("Asking for approval picks up the request this device already has open")
    func askPicksUpTheOpenRequest() async {
        let fixture = AccountKeysFixture()
        fixture.flows.state = .needsApproval(request: "request-open")
        let model = fixture.model()
        await model.reload()

        model.askForApproval()

        guard case .approval(let flow)? = model.sheet else {
            Issue.record("Asking must open the approval sheet")
            return
        }
        #expect(flow.request == "request-open")
        #expect(flow.isNewDevice)
    }

    @Test("Each lock names its cause and offers only the ways back it leaves")
    func lockCauses() {
        #expect(!AccountKeysText.canAskForApproval(.deviceRemoved) && !AccountKeysText.canRecover(.deviceRemoved))
        #expect(AccountKeysText.canAskForApproval(.leftOutOfRotation) && AccountKeysText.canRecover(.leftOutOfRotation))
        #expect(AccountKeysText.canAskForApproval(.ownAccountReset) && !AccountKeysText.canRecover(.ownAccountReset))
        #expect(!AccountKeysText.canAskForApproval(.accountEnded) && !AccountKeysText.canRecover(.accountEnded))
    }

    @Test("A refusal reads by the server's change code where it gave one, and a lock by its cause")
    func refusalsReadByCode() {
        let refused = FakeAccountKeyFlows.failure("sync.rejected", sync: .rejected(code: "request_closed"))
        let locked = FakeAccountKeyFlows.failure("sync.locked", sync: .locked(cause: .leftOutOfRotation))

        #expect(AccountKeysText.message(for: refused) == String(localized: "This request has ended."))
        #expect(AccountKeysText.message(for: locked) == AccountKeysText.lockMessage(.leftOutOfRotation))
        #expect(AccountKeysText.message(for: FakeAccountKeyFlows.failure("keys.signature")) != AccountKeysText.generic)
        #expect(AccountKeysText.message(for: KeyServiceUnavailable()) != AccountKeysText.generic)
    }
}
