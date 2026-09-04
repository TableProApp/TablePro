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
internal enum UITestPoll {
    internal static func until(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
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

    /// Existence is not clickability. An element mid-animation, behind a sheet, or scrolled out of
    /// its container exists and hit-tests to nothing, so a click on it lands somewhere else or is
    /// swallowed. Wait on this before clicking anything the app has just revealed.
    func waitToBeHittable(timeout: TimeInterval) -> Bool {
        UITestPoll.until(timeout: timeout) { self.exists && self.isHittable }
    }
}
