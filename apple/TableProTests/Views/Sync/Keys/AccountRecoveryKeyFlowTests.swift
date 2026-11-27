//
//  AccountRecoveryKeyFlowTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
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
        #expect(flow.check == [2, 10])
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
        #expect(flow.failure != nil)
        flow.showKeyAgain()
        #expect(flow.step == .showKey)
        #expect(flow.failure == nil)
        #expect(flow.groups.count == 14)
    }

    @Test("When another device's setup won, this Mac is told to ask that one for approval")
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

    @Test("A setup that could not make a key says why and tries again")
    func failedStartRetries() async {
        let flows = FakeAccountKeyFlows()
        flows.fail("beginGenesis", with: FakeAccountKeyFlows.failure("sync.network"))
        let flow = Self.flow(.setUp, flows)

        await flow.start()
        #expect(!flow.hasKey)
        #expect(flow.failure != nil)
        await flow.start()

        #expect(flow.hasKey)
        #expect(flows.calls(named: "beginGenesis").count == 2)
    }

    @Test("Replace takes the current key, keeps only compared devices it ticked, and drops the typed key")
    func replaceKeepsComparedDevices() async {
        let flows = FakeAccountKeyFlows()
        let this = FakeAccountKeyFlows.device("key-this", thisDevice: true)
        let mini = FakeAccountKeyFlows.device("key-mini", compared: true)
        let phone = FakeAccountKeyFlows.device("key-phone", compared: true)
        let stranger = FakeAccountKeyFlows.device("key-stranger")
        flows.rotationDevices = [
            ReviewedDeviceInfo(device: this, keepByDefault: false),
            ReviewedDeviceInfo(device: mini, keepByDefault: true),
            ReviewedDeviceInfo(device: phone, keepByDefault: true),
            ReviewedDeviceInfo(device: stranger, keepByDefault: true),
        ]
        let flow = Self.flow(.replace, flows)
        #expect(flow.step == .enterCurrentKey)
        #expect(!flow.canContinue)
        flow.currentKey = FakeAccountKeyFlows.recoveryKey

        await flow.advance()

        #expect(flow.currentKey.isEmpty)
        #expect(flow.step == .chooseDevices)
        #expect(flow.keep == ["key-mini", "key-phone"])
        #expect(!flow.canKeep(flows.rotationDevices[0]))
        #expect(!flow.canKeep(flows.rotationDevices[3]))
        flow.setKeep(flows.rotationDevices[2], false)
        flow.setKeep(flows.rotationDevices[3], true)
        await flow.advance()
        #expect(flow.step == .showKey)
        await flow.advance()
        flow.typed = Self.groups([0, 13])
        await flow.advance()

        #expect(flow.step == .done)
        #expect(flows.calls(named: "beginReplace") == [FakeAccountKeyFlows.Call("beginReplace", [FakeAccountKeyFlows.recoveryKey])])
        #expect(flows.calls(named: "finishReplace") == [FakeAccountKeyFlows.Call("finishReplace", ["replace-1"] + Self.groups([0, 13]) + ["key-mini"])])
    }

    @Test("A wrong current key stays on its field with the reason")
    func wrongCurrentKey() async {
        let flows = FakeAccountKeyFlows()
        flows.fail("beginReplace", with: FakeAccountKeyFlows.failure("keys.recovery_key"))
        let flow = Self.flow(.replace, flows)
        flow.currentKey = "WRONG"

        await flow.advance()

        #expect(flow.step == .enterCurrentKey)
        #expect(flow.failure != nil)
        #expect(flow.currentKey == "WRONG")
    }

    @Test("Closing the sheet drops the key it showed, and the core drops its draft")
    func discardDropsTheKey() async throws {
        let flows = FakeAccountKeyFlows()
        let flow = Self.flow(.setUp, flows)
        await flow.start()

        flow.discard()

        #expect(!flow.hasKey)
        #expect(flow.groups.isEmpty)
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

        #expect(!flow.hasKey)
        #expect(flows.calls(named: "discardKeyDraft").isEmpty)
    }
}
