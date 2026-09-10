//
//  LoadingRevealPolicy.swift
//  TablePro
//

import Foundation

/// When progress UI has earned its place on screen.
///
/// Two rules, and the second is the one that gets left out. Work that finishes inside `grace`
/// shows nothing at all, because an indicator the user cannot read costs a view hierarchy to
/// build and tear down and tells them nothing. Work that outlasts it keeps its indicator for
/// `minimumDwell`, because an indicator revealed at 500ms over work that ends at 510ms is a 10ms
/// flash, which is worse than either of the states it sits between.
///
/// The HIG carries the same rule from both ends: progress indicators are for "situations where
/// loading takes more than a moment or two", and a first screen that differs from what replaces it
/// gives "an unpleasant flash between the launch screen and your first screen".
internal enum LoadingRevealPolicy {
    /// Long enough that nothing local ever reaches it, short enough to stay under the one second
    /// at which a wait stops feeling like part of the same gesture. It is the value
    /// `DelayedProgressIndicator` already used for schema refreshes.
    internal static let grace: Duration = .milliseconds(500)

    internal static let minimumDwell: Duration = .milliseconds(500)

    /// How much longer an indicator revealed at `revealedAt` has to stay before it may go.
    ///
    /// Measured from the reveal rather than from the moment the work ended, so anything slow
    /// enough to have shown an indicator at all has usually already served its dwell and hides
    /// the instant it finishes. Only the narrow band just past the grace waits.
    internal static func remainingDwell(
        revealedAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) -> Duration {
        let shown = revealedAt.duration(to: now)
        guard shown < minimumDwell else { return .zero }
        return minimumDwell - shown
    }
}
