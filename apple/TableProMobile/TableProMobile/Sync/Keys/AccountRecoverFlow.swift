import Foundation
import Observation

// Recovery with the recovery key on a device with no approved device at hand (core ADR 0056, Recovery with R). It
// compared with no device, so its rotation keeps only this device and every other one asks it for approval afterwards.
@MainActor @Observable
final class AccountRecoverFlow: Identifiable {
    let id = UUID()
    var recoveryKey = ""
    private(set) var isWorking = false
    private(set) var failure: String?
    private(set) var isDone = false

    @ObservationIgnored private let flows: @MainActor () async throws -> any AccountKeyFlows
    @ObservationIgnored private var closed = false

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
            AccountKeysText.log(error, while: "Recovery with the recovery key")
            failure = AccountKeysText.message(for: error)
        }
    }

    func discard() {
        closed = true
        recoveryKey = ""
    }
}
