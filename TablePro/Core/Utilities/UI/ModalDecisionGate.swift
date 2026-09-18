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

/// How large a hosted decision's window is allowed to be.
///
/// A content size has to be bounded before it reaches a window, not merely finite. `NSWindow`
/// asserts its frame lies inside `CGRect(INT_MIN, INT_MIN, INT_MAX - INT_MIN, INT_MAX - INT_MIN)`,
/// and a greedy SwiftUI root answers an unbounded proposal with `CGFloat.greatestFiniteMagnitude`,
/// which passes `isFinite` and fails that assertion. The `NSInternalInconsistencyException` it
/// raises is not contained: it unwinds a Swift concurrency job past the bare `leave()` that
/// `swift_job_runImpl` pops its `ExecutorTrackingInfo` with, leaving the main thread a dangling
/// executor for the next main-actor isolation check anywhere in the app to dereference. (#2930)
internal enum ModalDecisionWindowSizing {
    /// A process the MCP bridge started can route a decision with no window and no `NSScreen.main`.
    internal static let fallbackScreenSize = NSSize(width: 1_280, height: 800)

    @MainActor
    internal static func availableSize(for window: NSWindow?) -> NSSize {
        (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? fallbackScreenSize
    }

    /// A screen's visible frame bounds the *window*, and a titled window is taller than its content
    /// by its chrome, so the content gets what is left after the chrome rather than the whole frame.
    internal static func contentBudget(within available: NSSize, styleMask: NSWindow.StyleMask) -> NSSize {
        let content = NSWindow.contentRect(
            forFrameRect: NSRect(origin: .zero, size: available),
            styleMask: styleMask
        ).size
        return NSSize(width: max(content.width, 0), height: max(content.height, 0))
    }

    internal static func proposal(width: CGFloat, within available: NSSize) -> NSSize {
        NSSize(width: width, height: available.height)
    }

    internal static func contentSize(fitting fitted: NSSize, within available: NSSize) -> NSSize {
        NSSize(
            width: bounded(fitted.width, by: available.width),
            height: bounded(fitted.height, by: available.height)
        )
    }

    private static func bounded(_ value: CGFloat, by limit: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return limit }
        return min(value, limit)
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
