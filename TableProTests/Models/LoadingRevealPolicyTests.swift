// The dwell half of the policy, which is the half that gets left out.
//
// A grace on its own trades one flicker for another: work that ends just past
// the grace shows a spinner for the handful of milliseconds between the two,
// which is worse than either showing it throughout or never showing it.

@testable import TablePro
import Testing

struct LoadingRevealPolicyTests {
    @Test func anIndicatorRevealedAMomentAgoHasToStay() {
        let revealedAt = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingDwell(
            revealedAt: revealedAt,
            now: revealedAt.advanced(by: .milliseconds(10))
        )

        #expect(remaining == .milliseconds(490), "10ms of spinner is a flash, not a report")
    }

    @Test func anIndicatorThatHasServedItsDwellMayGoAtOnce() {
        let revealedAt = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingDwell(
            revealedAt: revealedAt,
            now: revealedAt.advanced(by: .seconds(4))
        )

        #expect(remaining == .zero, "anything slow enough to show one has already earned it")
    }

    @Test func theDwellEndsExactlyAtItsBoundary() {
        let revealedAt = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingDwell(
            revealedAt: revealedAt,
            now: revealedAt.advanced(by: LoadingRevealPolicy.minimumDwell)
        )

        #expect(remaining == .zero)
    }

    /// A clock that has not moved is what a same-run-loop-turn reveal and hide look like, and the
    /// answer has to be the whole dwell rather than zero.
    @Test func anIndicatorRevealedAndFinishedInTheSameInstantStaysForTheWholeDwell() {
        let revealedAt = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingDwell(revealedAt: revealedAt, now: revealedAt)

        #expect(remaining == LoadingRevealPolicy.minimumDwell)
    }

    @Test func theGraceStaysUnderTheSecondAtWhichAWaitStopsFeelingLikeOneGesture() {
        #expect(LoadingRevealPolicy.grace < .seconds(1))
    }

    @Test func workNobodySawStartWaitsTheWholeGrace() {
        #expect(LoadingRevealPolicy.remainingGrace(activeSince: nil, now: .now) == LoadingRevealPolicy.grace)
    }

    @Test func theGraceCountsFromWhenTheWorkStarted() {
        let started = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingGrace(
            activeSince: started,
            now: started.advanced(by: .milliseconds(200))
        )

        #expect(remaining == .milliseconds(300))
    }

    @Test func workAlreadyPastTheGraceRevealsAtOnce() {
        let started = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingGrace(
            activeSince: started,
            now: started.advanced(by: .seconds(2))
        )

        #expect(remaining == .zero)
    }

    @Test func aStartAfterNowWaitsTheWholeGrace() {
        let now = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingGrace(activeSince: now.advanced(by: .seconds(1)), now: now)

        #expect(remaining == LoadingRevealPolicy.grace)
    }
}
