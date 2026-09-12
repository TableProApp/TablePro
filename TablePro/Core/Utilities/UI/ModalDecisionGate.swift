//
//  ModalDecisionGate.swift
//  TablePro
//

import AppKit

/// A hosted modal can be answered twice: the view's own button and the window closing both arrive.
/// Only the first counts, or a continuation resumes more than once and the process traps.
///
/// `cancellationOutcome` is what closing the window means to this particular modal. Pairing treats
/// it as a thrown cancellation; a statement confirmation treats it as an ordinary no.
@MainActor
internal final class ModalDecisionGate<Value: Sendable> {
    internal var onResolve: (() -> Void)?

    /// `NSWindow.delegate` is weak and the sheet path returns while the sheet is still up, so the
    /// delegate that reports a close has to be owned by something whose lifetime matches the modal.
    internal var windowDelegate: (any NSWindowDelegate)?

    private let cancellationOutcome: Result<Value, Error>
    private var outcome: Result<Value, Error>?
    private var waiter: CheckedContinuation<Value, Error>?

    internal init(cancellationOutcome: Result<Value, Error>) {
        self.cancellationOutcome = cancellationOutcome
    }

    internal func deliver(_ result: Result<Value, Error>) {
        guard outcome == nil else { return }
        outcome = result
        onResolve?()
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(with: result)
    }

    internal func cancel() {
        deliver(cancellationOutcome)
    }

    internal func value() async throws -> Value {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    internal func result() throws -> Value {
        guard let outcome else { return try cancellationOutcome.get() }
        return try outcome.get()
    }
}

internal extension ModalDecisionGate where Value == PairingApproval {
    static func pairing() -> ModalDecisionGate<PairingApproval> {
        ModalDecisionGate(cancellationOutcome: .failure(DatabaseAccessError.userCancelled))
    }
}

internal extension ModalDecisionGate where Value == Bool {
    static func confirmation() -> ModalDecisionGate<Bool> {
        ModalDecisionGate(cancellationOutcome: .success(false))
    }
}

/// The window a hosted decision lives in, so Escape has somewhere to land.
///
/// A local `.keyDown` monitor cannot serve: measured on macOS 26.6, one installed over this sheet
/// reports Tab and every letter and never reports key code 53, because AppKit turns Escape into
/// `cancelOperation(_:)` and sends it up the responder chain first. Inside a hosted SwiftUI view
/// neither `.onExitCommand` nor a `.cancelAction` button answers it, and the window is the end of
/// that chain.
@MainActor
internal final class ModalDecisionWindow: NSWindow {
    internal var onCancel: (() -> Void)?

    override internal func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Closing the window is an answer, so it has to reach the gate rather than leave the caller
/// waiting on a modal that is no longer on screen.
@MainActor
internal final class ModalDecisionWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    internal init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    internal func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
