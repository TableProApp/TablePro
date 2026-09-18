//
//  LoadingReveal.swift
//  TablePro
//

import SwiftUI

/// Drives one Bool from `LoadingRevealPolicy`: false until the work behind it outlasts the grace,
/// then true for at least the minimum dwell.
///
/// A modifier rather than a wrapper view, because the answer often decides which branch a view
/// renders rather than whether one spinner sits inside it. `ExecutionIndicatorView` is the case
/// that needs it: holding its content back would leave an empty toolbar item, where holding the
/// state back leaves the previous readout standing and the row never changes width.
private struct LoadingRevealGate: ViewModifier {
    let isActive: Bool
    @Binding var isRevealed: Bool

    @State private var revealedAt: ContinuousClock.Instant?

    func body(content: Content) -> some View {
        content.task(id: isActive) { await track() }
    }

    private func track() async {
        guard isActive else {
            await hideAfterDwell()
            return
        }
        guard revealedAt == nil else { return }
        try? await Task.sleep(for: LoadingRevealPolicy.grace)
        guard !Task.isCancelled else { return }
        revealedAt = .now
        isRevealed = true
    }

    private func hideAfterDwell() async {
        guard let revealedAt else {
            isRevealed = false
            return
        }
        let remaining = LoadingRevealPolicy.remainingDwell(revealedAt: revealedAt, now: .now)
        if remaining > .zero {
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
        }
        self.revealedAt = nil
        isRevealed = false
    }
}

internal extension View {
    /// Reports through `isRevealed` whether progress UI for `isActive` has earned its place yet.
    func loadingRevealGate(isActive: Bool, isRevealed: Binding<Bool>) -> some View {
        modifier(LoadingRevealGate(isActive: isActive, isRevealed: isRevealed))
    }
}

/// Holds progress UI back until the work behind it outlasts `LoadingRevealPolicy.grace`.
///
/// The content is not built while it is held back, which is the point: a spinner that exists for
/// 40ms still costs a view hierarchy to reconcile in and out, and on the startup path that is work
/// paid for something nobody sees.
///
/// The dwell only bites where the alternative to the indicator is a view that was already there,
/// as it is in the toolbar, where hiding the executing cluster puts the previous duration back.
/// Where the alternative is the real content, the content wins: holding a loaded table list behind
/// half a second of spinner would be worse than the flash the dwell exists to prevent.
internal struct LoadingReveal<Content: View>: View {
    internal let isActive: Bool
    @ViewBuilder internal let content: () -> Content

    @State private var isRevealed = false

    internal var body: some View {
        Group {
            if isRevealed {
                content()
            }
        }
        .loadingRevealGate(isActive: isActive, isRevealed: $isRevealed)
    }
}
