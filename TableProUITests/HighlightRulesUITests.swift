//
//  HighlightRulesUITests.swift
//  TableProUITests
//

import AppKit
import XCTest

final class HighlightRulesUITests: UITestCase {
    func testAddingARuleFromTheStatusBarKeepsItForTheTable() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        _ = try albumGrid(in: window)

        openRulesFromStatusBar(in: window)
        let add = window.buttons["highlight-rules-add"].firstMatch
        XCTAssertTrue(waitUntilHittable(add, timeout: 10), "The popover must offer Add Rule")
        XCTAssertFalse(ruleCheckbox(in: window).exists, "A table nobody highlighted starts with no rules")
        add.click()
        XCTAssertTrue(ruleCheckbox(in: window).waitToExist(timeout: 10), "Add Rule must list a new rule")
        app.typeText("1")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(add.waitForNonExistence(timeout: 5), "Escape in the value field must close the popover")

        openRulesFromStatusBar(in: window)
        XCTAssertTrue(
            ruleCheckbox(in: window).waitToExist(timeout: 10),
            "A rule belongs to the table, so reopening the popover lists it again"
        )

        let reopenedAdd = window.buttons["highlight-rules-add"].firstMatch
        XCTAssertTrue(waitUntilHittable(reopenedAdd, timeout: 10))
        reopenedAdd.click()
        XCTAssertTrue(waitForPredicate(timeout: 10) { self.ruleCheckboxes(in: window).count == 2 })
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(reopenedAdd.waitForNonExistence(timeout: 5))

        openRulesFromStatusBar(in: window)
        XCTAssertTrue(ruleCheckbox(in: window).waitToExist(timeout: 10))
        XCTAssertEqual(ruleCheckboxes(in: window).count, 1, "A rule closed without a value is not kept")
    }

    func testChangingARulesColumnKeepsTheColumnItWasGiven() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        _ = try albumGrid(in: window)

        openRulesFromStatusBar(in: window)
        let add = window.buttons["highlight-rules-add"].firstMatch
        XCTAssertTrue(waitUntilHittable(add, timeout: 10), "The popover must offer Add Rule")
        add.click()

        let column = window.popUpButtons.matching(identifier: "highlight-rule-column").firstMatch
        XCTAssertTrue(waitUntilHittable(column, timeout: 10), "A rule must offer its column")
        let initial = column.value as? String
        XCTAssertNotNil(initial, "The column pull-down must publish the column it is set to")

        let chosen = initial == "Title" ? "AlbumId" : "Title"
        column.click()
        let item = app.menuItems[chosen].firstMatch
        XCTAssertTrue(waitUntilHittable(item, timeout: 10), "The column menu must offer \(chosen)")
        item.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { column.value as? String == chosen },
            "Picking \(chosen) must leave the rule on it, not revert to \(initial ?? "")"
        )
    }

    func testChangingARulesOperatorKeepsTheOperatorItWasGiven() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        _ = try albumGrid(in: window)

        openRulesFromStatusBar(in: window)
        let add = window.buttons["highlight-rules-add"].firstMatch
        XCTAssertTrue(waitUntilHittable(add, timeout: 10), "The popover must offer Add Rule")
        add.click()

        let operatorMenu = window.descendants(matching: .any)
            .matching(identifier: "highlight-rule-operator").firstMatch
        XCTAssertTrue(waitUntilHittable(operatorMenu, timeout: 10), "A rule must offer its operator")
        XCTAssertEqual(operatorMenu.value as? String, "equals", "A new rule starts on equals")

        operatorMenu.click()
        let contains = app.menuItems["contains"].firstMatch
        XCTAssertTrue(waitUntilHittable(contains, timeout: 10), "The operator menu must list contains")
        contains.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { operatorMenu.value as? String == "contains" },
            "Picking contains must leave the rule on contains, not revert to equals"
        )
    }

    func testTheCellMenuOffersHighlightAndOpensTheRules() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try albumGrid(in: window)

        let cell = gridPoint(in: grid, of: window, dy: 70)
        cell.click()
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
        cell.rightClick()

        let highlight = window.menus.menuItems["Highlight"].firstMatch
        XCTAssertTrue(highlight.waitToExist(timeout: 15), "A cell's context menu must offer Highlight")
        highlight.hover()

        let showRules = contextMenuItem("Highlight Rules…", in: app)
        XCTAssertTrue(waitUntilHittable(showRules, timeout: 10), "The Highlight submenu must offer Highlight Rules…")
        showRules.click()

        XCTAssertTrue(
            window.buttons["highlight-rules-add"].firstMatch.waitToExist(timeout: 10),
            "Highlight Rules… must open the rules popover"
        )
    }

    // MARK: - Helpers

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }

    private func albumGrid(in window: XCUIElement) throws -> XCUIElement {
        let row = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: Album"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "Album produced no data grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "Album must load rows before a cell can be highlighted")
        return grid
    }

    private func openRulesFromStatusBar(in window: XCUIElement) {
        let button = window.buttons["result-status-highlight"]
        XCTAssertTrue(waitUntilHittable(button, timeout: 15), "The status bar must offer Highlight")
        button.click()
    }

    private func ruleCheckbox(in window: XCUIElement) -> XCUIElement {
        ruleCheckboxes(in: window).firstMatch
    }

    private func ruleCheckboxes(in window: XCUIElement) -> XCUIElementQuery {
        window.checkBoxes.matching(identifier: "highlight-rule-enabled")
    }
}
