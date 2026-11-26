//
//  AccountRecoveryKeyFlow.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI

// A new recovery key, shown once and checked by two groups typed back before anything is pushed (core ADR 0056, The
// recovery key): the first one at genesis, or a replacement, which first takes the current key and asks which compared
// devices keep their keys. The key lives here only while the sheet is open.
@MainActor
internal final class AccountRecoveryKeyFlow: ObservableObject, Identifiable {
    enum Purpose: Equatable {
        case setUp
        case replace
    }

    enum Step: Equatable {
        case enterCurrentKey
        case chooseDevices
        case showKey
        case typeBack
        // Another device's genesis applied first, so this one asks for approval instead.
        case anotherDeviceWon
        case done
    }

    let id = UUID()
    let purpose: Purpose
    @Published private(set) var step: Step
    @Published private(set) var isWorking = false
    @Published private(set) var failure: String?
    @Published var currentKey = ""
    @Published var typed = ["", ""]
    @Published private(set) var keep: Set<String> = []
    @Published private(set) var groups: [String] = []
    // The 0-based groups to type back, in the order `typed` holds them.
    @Published private(set) var check: [Int] = []
    @Published private(set) var devices: [ReviewedDeviceInfo] = []

    private let flows: @MainActor () async throws -> any AccountKeyFlows
    private var draft: String?
    // The sheet closed while a call was out: what it answers is dropped.
    private var closed = false

    init(purpose: Purpose, flows: @escaping @MainActor () async throws -> any AccountKeyFlows) {
        self.purpose = purpose
        self.flows = flows
        step = purpose == .replace ? .enterCurrentKey : .showKey
    }

    var hasKey: Bool {
        draft != nil
    }

    var canContinue: Bool {
        guard !isWorking else { return false }
        switch step {
        case .enterCurrentKey: return !currentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .chooseDevices, .showKey: return draft != nil
        case .typeBack: return typed.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .anotherDeviceWon, .done: return true
        }
    }

    // A device the rotation may keep: one this Mac compared words with. This Mac always stays.
    func canKeep(_ device: ReviewedDeviceInfo) -> Bool {
        device.device.compared && !device.device.thisDevice
    }

    func setKeep(_ device: ReviewedDeviceInfo, _ kept: Bool) {
        guard canKeep(device) else { return }
        if kept {
            keep.insert(device.device.keyDevice)
        } else {
            keep.remove(device.device.keyDevice)
        }
    }

    // Genesis draws its key as the sheet opens.
    func start() async {
        guard purpose == .setUp, draft == nil, !isWorking, !closed else { return }
        await working {
            let made = try await self.flows().beginGenesis()
            guard !self.closed else { return }
            self.adopt(made)
        }
    }

    func advance() async {
        guard canContinue else { return }
        failure = nil
        switch step {
        case .enterCurrentKey:
            await beginReplace()
        case .chooseDevices:
            step = .showKey
        case .showKey:
            typed = ["", ""]
            step = .typeBack
        case .typeBack:
            await finish()
        case .anotherDeviceWon, .done:
            break
        }
    }

    // Back to the key from the check, before anything is pushed.
    func showKeyAgain() {
        guard step == .typeBack, !isWorking else { return }
        failure = nil
        step = .showKey
    }

    // The sheet closed: what it held goes with it, and a call still out lands nowhere.
    func discard() {
        closed = true
        clearSecrets()
    }

    private func clearSecrets() {
        draft = nil
        groups = []
        check = []
        typed = ["", ""]
        currentKey = ""
    }

    var keyText: String {
        groups.joined(separator: "-")
    }

    private func beginReplace() async {
        let recoveryKey = currentKey
        await working {
            let rotation = try await self.flows().beginReplaceRecoveryKey(recoveryKey: recoveryKey)
            guard !self.closed else { return }
            self.currentKey = ""
            self.devices = rotation.devices
            self.keep = Set(rotation.devices.filter { $0.keepByDefault && self.canKeep($0) }.map(\.device.keyDevice))
            self.adopt(rotation.recovery)
            self.step = rotation.devices.contains { !$0.device.thisDevice } ? .chooseDevices : .showKey
        }
    }

    private func finish() async {
        guard let draft else { return }
        let typed = typed
        let keep = devices.map(\.device.keyDevice).filter { self.keep.contains($0) }
        await working {
            let flows = try await self.flows()
            switch self.purpose {
            case .setUp:
                let outcome = try await flows.finishGenesis(draft: draft, typed: typed)
                self.step = outcome == .anotherDeviceWon ? .anotherDeviceWon : .done
            case .replace:
                try await flows.finishReplaceRecoveryKey(draft: draft, typed: typed, keep: keep)
                self.step = .done
            }
            self.clearSecrets()
        }
    }

    private func adopt(_ made: RecoveryKeyDraftInfo) {
        draft = made.draft
        groups = made.text.split(separator: "-").map(String.init)
        check = Array(made.check).map(Int.init)
        if purpose == .setUp {
            step = .showKey
        }
    }

    private func working(_ body: @MainActor () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await body()
        } catch {
            guard !closed else { return }
            failure = AccountKeysText.message(for: error)
        }
    }
}
