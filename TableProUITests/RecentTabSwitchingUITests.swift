//
//  RecentTabSwitchingUITests.swift
//  TableProUITests
//
//  Control-Tab walks the window's tabs in the order they were used, not the order the strip draws
//  them. (#2524)
//

import AppKit
import XCTest

final class RecentTabSwitchingUITests: UITestCase {
    /// After opening Album, Artist, Customer and Employee, then selecting Album and Employee, the
    /// order is Employee, Album, Customer, Artist. A tap goes back one tab and a second tap comes
    /// back. Holding Control is covered by RecentTabSwitcherControllerTests.
    func testControlTabWalksTabsInTheOrderTheyWereUsed() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        openTables(["Album", "Artist", "Customer", "Employee"], in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) {
                Set(self.tabLabels(in: window)).isSuperset(of: ["Album", "Artist", "Customer", "Employee"])
            },
            "The strip must show a tab per opened table, got \(tabLabels(in: window))"
        )

        select("Album", in: window)
        select("Employee", in: window)

        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(
            waitForSelection("Album", in: window),
            "A tap must go back to Album, the tab used before Employee, not its strip neighbour. Got "
                + (selectedTabLabel(in: window) ?? "none")
        )

        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(waitForSelection("Employee", in: window), "A second tap must come back to Employee")
    }

    // MARK: - Helpers

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }

    /// Double-clicked, because a single click opens a preview tab that the next table takes over.
    private func openTables(_ names: [String], in window: XCUIElement) {
        for name in names {
            let row = objectBrowserRow(name, in: window)
            XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(name)")
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
            Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
        }
    }

    private func tabElements(in window: XCUIElement) -> [XCUIElement] {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .allElementsBoundByIndex
    }

    private func tabLabels(in window: XCUIElement) -> [String] {
        tabElements(in: window).map { $0.label }
    }

    private func selectedTabLabel(in window: XCUIElement) -> String? {
        tabElements(in: window).first { $0.isSelected }?.label
    }

    private func waitForSelection(_ name: String, in window: XCUIElement) -> Bool {
        waitForPredicate(timeout: 10) { self.selectedTabLabel(in: window) == name }
    }

    private func select(_ name: String, in window: XCUIElement) {
        let tab = window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
        XCTAssertTrue(waitUntilHittable(tab, timeout: 20), "The \(name) tab must be on screen")
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitForSelection(name, in: window), "Clicking the \(name) tab must select it")
    }
}
