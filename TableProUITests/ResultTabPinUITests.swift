//
//  ResultTabPinUITests.swift
//  TableProUITests
//
//  Covers #1982: pinning a query result must be reachable from the result tab itself.
//  The query is padded past the height of the editor pane because that is what used to
//  make the editor claim right-clicks over the results.
//

import XCTest

final class ResultTabPinUITests: UITestCase {
    func testResultTabExposesPinButtonAndPinMenuItem() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
        app.typeText(paddedQuery)
        app.typeKey(.return, modifierFlags: .command)

        let resultTab = app.buttons["result-tab"].firstMatch
        XCTAssertTrue(resultTab.waitToExist(timeout: 20), "The query must produce a result tab")
        resultTab.rightClick()

        /// A contextual menu opens inside the window; the menu-bar menus hang off `MenuBar`, so
        /// scoping to the window isolates the one that just opened. Matching on the menu's
        /// accessibility identifier instead worked here but not on the CI runner, whose macOS
        /// build exposes the menu without it.
        let contextMenu = app.windows.firstMatch.menus.firstMatch
        XCTAssertTrue(
            contextMenu.menuItems["Close Others"].waitToExist(timeout: 5),
            "Right-clicking a result tab must open the result menu, not the editor menu"
        )
        contextMenu.menuItems["Pin Result"].click()

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["View"].click()
        let unpinItem = menuBar.menuItems["Unpin Result"]
        XCTAssertTrue(unpinItem.waitToExist(timeout: 5), "A pinned result reads as Unpin Result")
        XCTAssertTrue(unpinItem.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Sixty blank lines, not sixty comments. The editor ends up the same height either way, but
    /// XCUITest synthesizes typing at roughly 113ms per character, so the 660-character version
    /// spent 74 seconds of this test's 103 pressing keys.
    private var paddedQuery: String {
        String(repeating: "\n", count: 60) + "SELECT 1;"
    }
}
