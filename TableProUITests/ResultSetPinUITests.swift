//
//  ResultSetPinUITests.swift
//  TableProUITests
//
//  Covers #1982: pinning a query result must be reachable from a control, not the View menu alone.
//  That control used to be the result strip's own tab; it is the status bar's result-set chooser
//  now, which is why the chooser is shown even for a single result.
//

import XCTest

final class ResultSetPinUITests: UITestCase {
    func testResultSetChooserOffersPinForASingleResult() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText("SELECT 1;")
        app.typeKey(.return, modifierFlags: .command)

        let chooser = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "result-set-menu")
            .firstMatch
        XCTAssertTrue(
            chooser.waitToExist(timeout: 20),
            "A single result still offers the chooser, because Pin lives in its menu"
        )
        XCTAssertTrue(waitUntilHittable(chooser, timeout: 10))
        chooser.click()

        /// The pull-down opens inside the window; the menu-bar menus hang off `MenuBar`, so scoping
        /// to the window isolates the one that just opened. Matching on the menu's accessibility
        /// identifier instead worked locally but not on the CI runner, whose macOS build exposes a
        /// just-opened menu without one.
        let menu = app.windows.firstMatch.menus.firstMatch
        XCTAssertTrue(
            menu.menuItems["Pin Result"].waitToExist(timeout: 5),
            "The chooser's menu must offer Pin Result"
        )
        XCTAssertTrue(
            menu.menuItems["Close Other Results"].exists,
            "Close Others survives the move off the strip"
        )
        menu.menuItems["Pin Result"].click()

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["View"].click()
        let unpinItem = menuBar.menuItems["Unpin Result"]
        XCTAssertTrue(unpinItem.waitToExist(timeout: 5), "A pinned result reads as Unpin Result")
        XCTAssertTrue(unpinItem.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }
}
