//
//  PairingApprovalGate.swift
//  TablePro
//

import AppKit

/// A pairing prompt can be answered twice: the sheet's own button and the window closing both
/// arrive. Only the first counts, or a continuation resumes more than once and the process traps.
@MainActor
internal final class PairingApprovalGate {
    internal var onResolve: (() -> Void)?

    private var outcome: Result<PairingApproval, Error>?
    private var waiter: CheckedContinuation<PairingApproval, Error>?

    internal func deliver(_ result: Result<PairingApproval, Error>) {
        guard outcome == nil else { return }
        outcome = result
        onResolve?()
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(with: result)
    }

    internal func cancel() {
        deliver(.failure(MCPDataLayerError.userCancelled))
    }

    internal func value() async throws -> PairingApproval {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    internal func result() throws -> PairingApproval {
        guard let outcome else { throw MCPDataLayerError.userCancelled }
        return try outcome.get()
    }
}

@MainActor
internal final class PairingApprovalWindowDelegate: NSObject, NSWindowDelegate {
    private let gate: PairingApprovalGate

    internal init(gate: PairingApprovalGate) {
        self.gate = gate
    }

    internal func windowWillClose(_ notification: Notification) {
        gate.cancel()
    }
}
