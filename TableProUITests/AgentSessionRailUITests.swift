//
//  AgentSessionRailUITests.swift
//  TableProUITests
//
//  The rail could only ever add sessions: there was no command anywhere in the app that deleted one,
//  so it grew without bound and its empty state was unreachable. Its bottom bar is a source list's
//  own add and remove pair now, and removing asks first.
//

import XCTest

final class AgentSessionRailUITests: UITestCase {
    /// The menu titles are matched by their English text, so the app runs in a known language.
    private let englishArguments = ["-AppleLanguages", "(en)"]

    func testTheRailAddsAndDeletesSessions() throws {
        let app = try launchWithSampleDatabase(arguments: englishArguments)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 20))
        enterAgentMode(in: app)

        let rail = sessionRail(in: window)
        XCTAssertTrue(rail.waitToExist(timeout: 20), "Agent mode opens a session, so the rail has one to list")
        let opened = rail.outlineRows.count

        let add = window.buttons["agent-session-add"].firstMatch
        XCTAssertTrue(waitUntilHittable(add, timeout: 15), "The rail's bottom bar adds to the list it sits under")
        add.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 15) { rail.outlineRows.count == opened + 1 },
            "New Session must add a row and select it"
        )

        let remove = window.buttons["agent-session-remove"].firstMatch
        XCTAssertTrue(waitUntilHittable(remove, timeout: 15), "A session is highlighted, so remove is live")
        remove.click()

        let confirm = app.sheets.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitToExist(timeout: 15), "Deleting a session throws its conversation away, so it asks")
        confirm.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 15) { rail.outlineRows.count == opened },
            "Answering the question takes the session out of the rail"
        )
    }

    /// Cancelling leaves the session where it was, which is the half of a confirmation that is worth
    /// as much as the other.
    func testCancellingTheQuestionKeepsTheSession() throws {
        let app = try launchWithSampleDatabase(arguments: englishArguments)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 20))
        enterAgentMode(in: app)

        let rail = sessionRail(in: window)
        XCTAssertTrue(rail.waitToExist(timeout: 20))
        let opened = rail.outlineRows.count

        let remove = window.buttons["agent-session-remove"].firstMatch
        XCTAssertTrue(waitUntilHittable(remove, timeout: 15))
        remove.click()

        let cancel = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitToExist(timeout: 15))
        cancel.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { rail.outlineRows.count == opened },
            "A refused question changes nothing"
        )
    }

    // MARK: - Helpers

    /// The mode is chosen from the menu bar, which reaches it at any window width; the toolbar has no
    /// mode control.
    private func enterAgentMode(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()
        menuBar.menuItems["Mode"].click()
        let agent = menuBar.menuItems["Agent"]
        XCTAssertTrue(agent.waitToExist(timeout: 10), "View > Mode must offer Agent")
        agent.click()
    }

    /// The rail is shown into the same column the object browser uses, so it is found the same way:
    /// stepping through the window's direct children rather than searching the whole window, which
    /// would walk the data grid's thousands of elements on the way.
    private func sessionRail(in window: XCUIElement) -> XCUIElement {
        window.children(matching: .splitGroup).firstMatch
            .children(matching: .group).firstMatch
            .descendants(matching: .outline).firstMatch
    }
}
