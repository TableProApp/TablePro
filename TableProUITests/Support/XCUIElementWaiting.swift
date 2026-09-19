//
//  XCUIElementWaiting.swift
//  TableProUITests
//

import XCTest

/// The one polling loop the suite waits on.
///
/// `XCUIElement.waitForExistence` builds an `XCTNSPredicateExpectation`, which schedules its first
/// evaluation about a second out, so a call pays a flat second even when the element is already on
/// screen. The suite has 188 existence waits and almost all of them are on the happy path, which
/// measured at 4.5 minutes of every CI run spent waiting for something already there. Checking
/// first and polling afterwards costs nothing when the element exists and is no slower when it
/// does not.
///
/// The pause after a miss is at least as long as the check that missed. XCTest evaluates a query
/// inside the app, on its main thread, so a check that walks a loaded data grid holds that thread
/// for as long as the walk takes. A fixed 50ms pause after a five second walk left the app about
/// 0.4s of every five, and the table list the suite was waiting for took 25 to 107 seconds to load
/// instead of one to ten (runs 35345089994 and 35375539350). Matching the pause to the check's own
/// cost leaves the app at least half of its main thread whatever a query costs.
internal enum UITestPoll {
    private static let minimumPause: TimeInterval = 0.05

    internal static func until(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let checkStarted = Date()
            if condition() { return true }
            let pause = max(minimumPause, Date().timeIntervalSince(checkStarted))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pause))
        }
        return condition()
    }
}

internal extension XCUIElement {
    /// Drop-in replacement for `waitForExistence(timeout:)` without its fixed first-evaluation
    /// delay. Prefer this everywhere; see `UITestPoll` for why.
    func waitToExist(timeout: TimeInterval) -> Bool {
        UITestPoll.until(timeout: timeout) { self.exists }
    }
}
