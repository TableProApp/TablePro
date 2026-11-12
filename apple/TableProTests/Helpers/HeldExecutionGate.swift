import Foundation
@testable import TablePro

// Holds every request until the test answers, as an approval prompt that is not window-modal does.
@MainActor
internal final class HeldExecutionGate: ExecutionGate {
    private(set) var askedCount = 0
    private var waiting: [(request: OperationRequest, continuation: CheckedContinuation<OperationDecision, Never>)] = []

    nonisolated internal func authorize(_ request: OperationRequest) async -> OperationDecision {
        await hold(request)
    }

    private func hold(_ request: OperationRequest) async -> OperationDecision {
        askedCount += 1
        return await withCheckedContinuation { waiting.append((request, $0)) }
    }

    internal func answer(allowing: Bool) async {
        let held = waiting
        waiting = []
        for entry in held {
            let decision: OperationDecision = allowing
                ? await AlwaysAllowGate().authorize(entry.request)
                : .denied(reason: "Refused by the test")
            entry.continuation.resume(returning: decision)
        }
    }
}
