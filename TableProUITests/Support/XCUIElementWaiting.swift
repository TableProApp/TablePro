import XCTest

// `waitForExistence` makes its first check about a second out, so this checks first. A query runs on the
// app's main thread, so each pause lasts as long as the check that missed and the app keeps half of it.
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
    func waitToExist(timeout: TimeInterval) -> Bool {
        UITestPoll.until(timeout: timeout) { self.exists }
    }
}
