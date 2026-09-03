//
//  StructureConstraintsTabUITests.swift
//  TableProUITests
//

import XCTest

final class StructureConstraintsTabUITests: UITestCase {
    /// The Constraints tab is gated on a per-engine capability, so the failure it guards against is
    /// a tab that never appears at all. SQLite declares check constraints, so the sample database
    /// is enough to prove the tab reaches the picker and renders when selected.
    func testConstraintsTabIsOfferedAndOpens() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let row = objectBrowserRow("Album", in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        showStructure(in: app, window: window)

        let constraints = subTab(named: "Constraints", in: window)
        XCTAssertTrue(
            constraints.waitToExist(timeout: 20),
            "SQLite declares check constraints, so the structure editor must offer Constraints"
        )
        constraints.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { isSelected(constraints) },
            "Selecting Constraints moves the picker to it"
        )
    }

    /// A radio button in a hosted picker reports `AXSelected` as nil and answers with `AXValue`
    /// instead, so `isSelected` reads as false however the picker is set.
    private func isSelected(_ segment: XCUIElement) -> Bool {
        (segment.value as? NSNumber)?.intValue == 1
    }

    /// The sub-tab labels carry item counts, so they are matched by prefix rather than exactly.
    private func subTab(named name: String, in window: XCUIElement) -> XCUIElement {
        window.radioGroups["structure-tab-picker"].firstMatch
            .radioButtons
            .matching(NSPredicate(format: "label BEGINSWITH %@", name))
            .firstMatch
    }
}
