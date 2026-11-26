//
//  AccountRecoverFlow.swift
//  TablePro
//

import Combine
import Foundation

// Recovery with the recovery key on a Mac with no approved device at hand (core ADR 0056, Recovery with R). It compared
// with no device, so its rotation keeps only this Mac and every other device asks this one for approval afterwards.
@MainActor
internal final class AccountRecoverFlow: ObservableObject, Identifiable {
    let id = UUID()
    @Published var recoveryKey = ""
    @Published private(set) var isWorking = false
    @Published private(set) var failure: String?
    @Published private(set) var isDone = false

    private let flows: @MainActor () async throws -> any AccountKeyFlows
    private var closed = false

    init(flows: @escaping @MainActor () async throws -> any AccountKeyFlows) {
        self.flows = flows
    }

    var canRecover: Bool {
        !isWorking && !recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func recover() async {
        guard canRecover, !closed else { return }
        let recoveryKey = recoveryKey
        failure = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await flows().recoverWithRecoveryKey(recoveryKey: recoveryKey)
            self.recoveryKey = ""
            isDone = true
        } catch {
            guard !closed else { return }
            failure = AccountKeysText.message(for: error)
        }
    }

    func discard() {
        closed = true
        recoveryKey = ""
    }
}
