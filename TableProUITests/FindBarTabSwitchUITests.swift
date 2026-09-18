//
//  FindBarTabSwitchUITests.swift
//  TableProUITests
//
//  The find bar holds its field text in the view's own `@State`, seeded once from `onAppear`. With
//  find open on both tabs the view kept its identity across a tab switch, so nothing re-seeded it
//  and the field showed the other tab's term. (#2667)
//

import XCTest

final class FindBarTabSwitchUITests: UITestCase {
    func testTheFindTermDoesNotFollowTheReaderToAnotherTab() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The sample table must produce a grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "The rows must be in before find can match any")

        openFind(in: app)
        let field = findField(in: window)
        XCTAssertTrue(field.waitToExist(timeout: 15), "Command F must open the find bar")
        field.click()
        app.typeText("alice")
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { Self.text(of: field) == "alice" },
            "The first tab's term must reach its field, got \(Self.text(of: field))"
        )

        /// A second table tab, with find open too. That is the case the fix is about: when the
        /// incoming tab has no find bar the view is destroyed anyway and the term reseeds itself.
        openSecondTableTab(in: app, window: window)
        XCTAssertTrue(waitForClickableRows(in: grid), "The second tab must load its rows")
        openFind(in: app)
        let secondField = findField(in: window)
        XCTAssertTrue(secondField.waitToExist(timeout: 15), "The second tab must offer its own find bar")
        secondField.click()
        app.typeText("berlin")
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { Self.text(of: secondField) == "berlin" },
            "The second tab's term must reach its field, got \(Self.text(of: secondField))"
        )

        showPreviousTab(in: app)

        let returned = findField(in: window)
        XCTAssertTrue(returned.waitToExist(timeout: 15), "The first tab must come back with its find bar")
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { Self.text(returned) == "alice" },
            "Returning to the first tab must show its own term, not the other tab's. Got "
                + Self.text(of: returned)
        )
    }

    // MARK: - Helpers

    private static func text(of element: XCUIElement) -> String {
        guard element.exists else { return "<no field>" }
        return (element.value as? String) ?? ""
    }

    private static func text(_ element: XCUIElement) -> String { text(of: element) }

    private func findField(in window: XCUIElement) -> XCUIElement {
        window.searchFields["find-in-results-field"].firstMatch
    }

    private func openFind(in app: XCUIApplication) {
        app.typeKey("f", modifierFlags: .command)
    }

    private func mainWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        return window
    }

    /// A second table tab, through the tree's own "Open in New Tab". A double-click would not do:
    /// without active work in the current tab, opening a table replaces it rather than adding one,
    /// and this test needs both tabs to exist at once.
    ///
    /// The tree draws its rows as hosted cells, so the name arrives as the static text's `value`
    /// rather than as a label, and the rows report as disabled. Matching on `value` finds them and a
    /// coordinate click reaches them.
    private func openSecondTableTab(in app: XCUIApplication, window: XCUIElement) {
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        let row = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: Album"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list a second table")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

        let item = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(item.waitToExist(timeout: 15), "The tree menu must offer Open in New Tab")
        item.click()
    }

    /// The menu item rather than its key equivalent, which is user-rebindable. `firstMatch` because
    /// the title is published more than once once AppKit's own window-tab machinery is involved.
    private func showPreviousTab(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 20), "The app must publish its menu bar")
        menuBar.menuBarItems["Window"].click()
        let item = menuBar.menuItems["Show Previous Tab"].firstMatch
        XCTAssertTrue(item.waitToExist(timeout: 10), "The Window menu must offer Show Previous Tab")
        item.click()
    }
}
