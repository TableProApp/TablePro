//
//  LoadingRevealPolicyTests.swift
//  TableProTests
//
//  The dwell half of the policy, which is the half that gets left out.
//
//  A grace on its own trades one flicker for another: work that ends just past
//  the grace shows a spinner for the handful of milliseconds between the two,
//  which is worse than either showing it throughout or never showing it.
//

@testable import TablePro
import XCTest

final class LoadingRevealPolicyTests: XCTestCase {
    func testAnIndicatorRevealedAMomentAgoHasToStay() {
        let revealedAt = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingDwell(
            revealedAt: revealedAt,
            now: revealedAt.advanced(by: .milliseconds(10))
        )

        XCTAssertEqual(remaining, .milliseconds(490), "10ms of spinner is a flash, not a report")
    }

    func testAnIndicatorThatHasServedItsDwellMayGoAtOnce() {
        let revealedAt = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingDwell(
            revealedAt: revealedAt,
            now: revealedAt.advanced(by: .seconds(4))
        )

        XCTAssertEqual(remaining, .zero, "anything slow enough to show one has already earned it")
    }

    func testTheDwellEndsExactlyAtItsBoundary() {
        let revealedAt = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingDwell(
            revealedAt: revealedAt,
            now: revealedAt.advanced(by: LoadingRevealPolicy.minimumDwell)
        )

        XCTAssertEqual(remaining, .zero)
    }

    /// A clock that has not moved is what a same-run-loop-turn reveal and hide look like, and the
    /// answer has to be the whole dwell rather than zero.
    func testAnIndicatorRevealedAndFinishedInTheSameInstantStaysForTheWholeDwell() {
        let revealedAt = ContinuousClock.now
        let remaining = LoadingRevealPolicy.remainingDwell(revealedAt: revealedAt, now: revealedAt)

        XCTAssertEqual(remaining, LoadingRevealPolicy.minimumDwell)
    }

    func testTheGraceStaysUnderTheSecondAtWhichAWaitStopsFeelingLikeOneGesture() {
        XCTAssertLessThan(LoadingRevealPolicy.grace, .seconds(1))
    }
}
