//
//  LoadingReveal.swift
//  TablePro
//

import Combine
import SwiftUI

/// Drives which subject's progress UI is revealed from `LoadingRevealPolicy`: none until the work
/// behind it outlasts the grace, then that subject for at least the minimum dwell.
///
/// A modifier rather than a wrapper view, because the answer often decides which branch a view
/// renders rather than whether one spinner sits inside it. The results status bar's execution
/// indicator is the case that needs it: holding its content back would leave an empty slot, where
/// holding the state back leaves the previous readout standing and the row never changes width.
private struct LoadingRevealGate<Subject: Hashable & Sendable>: ViewModifier {
    let subject: Subject
    let isActive: Bool
    let activeSince: ContinuousClock.Instant?
    @Binding var revealedSubject: Subject?

    @State private var revealedAt: ContinuousClock.Instant?

    func body(content: Content) -> some View {
        content.task(id: LoadingRevealActivity(subject: subject, isActive: isActive)) { await track() }
    }

    private func track() async {
        if let revealedSubject, revealedSubject != subject {
            self.revealedSubject = nil
            revealedAt = nil
        }
        guard isActive else {
            await hideAfterDwell()
            return
        }
        guard revealedAt == nil else { return }
        let grace = LoadingRevealPolicy.remainingGrace(activeSince: activeSince, now: .now)
        if grace > .zero {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
        }
        revealedAt = .now
        revealedSubject = subject
    }

    private func hideAfterDwell() async {
        guard let revealedAt else {
            revealedSubject = nil
            return
        }
        let remaining = LoadingRevealPolicy.remainingDwell(revealedAt: revealedAt, now: .now)
        if remaining > .zero {
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
        }
        self.revealedAt = nil
        revealedSubject = nil
    }
}

private struct LoadingRevealActivity<Subject: Hashable & Sendable>: Hashable {
    let subject: Subject
    let isActive: Bool
}

private enum UnscopedReveal: Hashable, Sendable {
    case subject
}

internal extension View {
    /// Reports through `isRevealed` whether progress UI for `isActive` has earned its place yet.
    func loadingRevealGate(isActive: Bool, isRevealed: Binding<Bool>) -> some View {
        modifier(LoadingRevealGate(
            subject: UnscopedReveal.subject,
            isActive: isActive,
            activeSince: nil,
            revealedSubject: Binding(
                get: { isRevealed.wrappedValue ? .subject : nil },
                set: { isRevealed.wrappedValue = $0 != nil }
            )
        ))
    }

    func loadingRevealGate<Subject: Hashable & Sendable>(
        for subject: Subject,
        isActive: Bool,
        activeSince: ContinuousClock.Instant?,
        revealedSubject: Binding<Subject?>
    ) -> some View {
        modifier(LoadingRevealGate(
            subject: subject,
            isActive: isActive,
            activeSince: activeSince,
            revealedSubject: revealedSubject
        ))
    }
}

// The content is not built until the grace passes. An empty view can host no `.task`, and an anchor view
// would take its stack's spacing, so the timer lives in a state object driven from `body`.
internal struct LoadingReveal<Content: View>: View {
    internal let isActive: Bool
    @ViewBuilder internal let content: () -> Content

    @StateObject private var clock = LoadingRevealClock()

    internal var body: some View {
        clock.track(isActive: isActive)
        return revealed
    }

    @ViewBuilder
    private var revealed: some View {
        if clock.isRevealed {
            content()
        }
    }
}

// Every change it publishes happens in its own task, never inside the `body` that called `track`.
@MainActor
private final class LoadingRevealClock: ObservableObject {
    @Published private(set) var isRevealed = false

    private var trackedActivity: Bool?
    private var revealedAt: ContinuousClock.Instant?
    private var pending: Task<Void, Never>?

    func track(isActive: Bool) {
        guard trackedActivity != isActive else { return }
        trackedActivity = isActive
        pending?.cancel()
        pending = Task { [weak self] in
            await self?.settle(isActive: isActive)
        }
    }

    private func settle(isActive: Bool) async {
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
        guard let revealedAt else { return }
        let remaining = LoadingRevealPolicy.remainingDwell(revealedAt: revealedAt, now: .now)
        if remaining > .zero {
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
        }
        self.revealedAt = nil
        isRevealed = false
    }
}
