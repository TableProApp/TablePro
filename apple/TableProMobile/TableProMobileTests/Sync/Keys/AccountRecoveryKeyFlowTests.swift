import Foundation
import TableProFFI
@testable import TableProMobile
import TableProTestSupport
import Testing

@MainActor
struct AccountRecoveryKeyFlowTests {
    private static func flow(_ purpose: AccountRecoveryKeyFlow.Purpose, _ flows: FakeAccountKeyFlows) -> AccountRecoveryKeyFlow {
        AccountRecoveryKeyFlow(purpose: purpose) { flows }
    }

    private static func groups(_ indexes: [Int]) -> [String] {
        let groups = FakeAccountKeyFlows.recoveryKey.split(separator: "-").map(String.init)
        return indexes.map { groups[$0] }
    }

    @Test("Setup shows the 14 groups, asks for the two the core named, and sends them in that order")
    func setUpTypesBackTheNamedGroups() async {
        let flows = FakeAccountKeyFlows()
        let flow = Self.flow(.setUp, flows)

        await flow.start()

        #expect(flow.step == .showKey)
        #expect(flow.groups.count == 14)
        #expect(flow.keyText == FakeAccountKeyFlows.recoveryKey)
        #expect(flow.checkedGroups == [3, 11])
        await flow.advance()
        #expect(flow.step == .typeBack)
        #expect(!flow.canContinue)
        flow.typed = Self.groups([2, 10])
        await flow.advance()

        #expect(flow.step == .done)
        #expect(flows.calls(named: "finishGenesis") == [FakeAccountKeyFlows.Call("finishGenesis", ["genesis-1"] + Self.groups([2, 10]))])
        #expect(flow.groups.isEmpty)
        #expect(!flow.hasKey)
    }

    @Test("Groups that don't match keep the check open with the reason, and the key can be shown again")
    func wrongGroupsStayOnTheCheck() async {
        let flows = FakeAccountKeyFlows()
        flows.fail("finishGenesis", with: FakeAccountKeyFlows.failure("sync.typed_back_wrong"))
        let flow = Self.flow(.setUp, flows)
        await flow.start()
        await flow.advance()
        flow.typed = ["0000", "0000"]

        await flow.advance()

        #expect(flow.step == .typeBack)
        #expect(flow.failure == AccountKeysText.message(code: "sync.typed_back_wrong"))
        flow.showKeyAgain()
        #expect(flow.step == .showKey)
        #expect(flow.failure == nil)
        #expect(flow.groups.count == 14)
    }

    @Test("When another device's setup won, this one is told to ask that one for approval")
    func anotherDeviceWon() async {
        let flows = FakeAccountKeyFlows()
        flows.genesisOutcome = .anotherDeviceWon
        let flow = Self.flow(.setUp, flows)
        await flow.start()
        await flow.advance()
        flow.typed = Self.groups([2, 10])

        await flow.advance()

        #expect(flow.step == .anotherDeviceWon)
    }

    @Test("Replace takes the current key, keeps only compared devices it ticked, and drops the typed key")
    func replaceKeepsComparedDevices() async {
        let flows = FakeAccountKeyFlows()
        flows.rotationDevices = [
            ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-this", thisDevice: true), keepByDefault: false),
            ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-mini", compared: true), keepByDefault: true),
            ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-mac", compared: true), keepByDefault: true),
            ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-stranger"), keepByDefault: true),
        ]
        let flow = Self.flow(.replace, flows)
        #expect(flow.step == .enterCurrentKey)
        #expect(!flow.canContinue)
        flow.currentKey = FakeAccountKeyFlows.recoveryKey

        await flow.advance()

        #expect(flow.currentKey.isEmpty)
        #expect(flow.step == .chooseDevices)
        #expect(flow.keep == ["key-mini", "key-mac"])
        flow.setKeep(flows.rotationDevices[2], false)
        flow.setKeep(flows.rotationDevices[3], true)
        await flow.advance()
        await flow.advance()
        flow.typed = Self.groups([0, 13])
        await flow.advance()

        #expect(flow.step == .done)
        #expect(flows.calls(named: "finishReplace") == [
            FakeAccountKeyFlows.Call("finishReplace", ["replace-1"] + Self.groups([0, 13]) + ["key-mini"]),
        ])
    }

    @Test("Closing the sheet drops the key it showed, and the core drops its draft")
    func discardDropsTheKey() async throws {
        let flows = FakeAccountKeyFlows()
        let flow = Self.flow(.setUp, flows)
        await flow.start()

        flow.discard()

        #expect(!flow.hasKey)
        #expect(flow.keyText.isEmpty)
        try await waitUntil { !flows.calls(named: "discardKeyDraft").isEmpty }
        #expect(flows.calls(named: "discardKeyDraft") == [FakeAccountKeyFlows.Call("discardKeyDraft", ["genesis-1"])])
    }

    @Test("A finished setup leaves no draft to discard")
    func finishedSetupDiscardsNothing() async {
        let flows = FakeAccountKeyFlows()
        let flow = Self.flow(.setUp, flows)
        await flow.start()
        await flow.advance()
        flow.typed = Self.groups([2, 10])
        await flow.advance()

        flow.discard()

        #expect(flows.calls(named: "discardKeyDraft").isEmpty)
    }

    @Test("Recovery with the key reports done and keeps nothing it was typed")
    func recoverWithTheKey() async {
        let flows = FakeAccountKeyFlows()
        let flow = AccountRecoverFlow { flows }
        flow.recoveryKey = FakeAccountKeyFlows.recoveryKey

        await flow.recover()

        #expect(flow.isDone)
        #expect(flow.recoveryKey.isEmpty)
        #expect(flows.calls(named: "recover") == [FakeAccountKeyFlows.Call("recover", [FakeAccountKeyFlows.recoveryKey])])
    }
}
