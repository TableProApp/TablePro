//
//  StructureTabIdentityUITests.swift
//  TableProUITests
//

import XCTest

final class StructureTabIdentityUITests: UITestCase {
    /// Two tabs on one table used to share a single structure editor, because the view took its
    /// SwiftUI identity from the table rather than from the tab. Where the user was in the editor is
    /// the cheapest observable proof of the sharing: moving the first tab to Indexes moved the
    /// second one with it.
    func testTwoTabsOnOneTableAreSeparateStructureEditors() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let row = objectBrowserRow("Album", in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        showStructure(in: window)
        let indexes = subTab(named: "Indexes", in: window)
        XCTAssertTrue(indexes.waitForExistence(timeout: 20), "The structure editor must offer Indexes")
        indexes.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { isSelected(indexes) },
            "The first tab is on Indexes"
        )

        row.rightClick()
        let openInNewTab = app.menuItems["Open in New Tab"].firstMatch
        XCTAssertTrue(openInNewTab.waitForExistence(timeout: 15), "The sidebar must offer Open in New Tab")
        openInNewTab.click()

        showStructure(in: window)
        let columns = subTab(named: "Columns", in: window)
        XCTAssertTrue(columns.waitForExistence(timeout: 20), "The second tab must have its own structure editor")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { isSelected(columns) },
            "The second tab opens on Columns rather than inheriting the first tab's Indexes"
        )
    }

    /// A radio button in a hosted picker reports `AXSelected` as nil and answers with `AXValue`
    /// instead, so `isSelected` reads as false however the picker is set.
    private func isSelected(_ segment: XCUIElement) -> Bool {
        (segment.value as? NSNumber)?.intValue == 1
    }

    private func showStructure(in window: XCUIElement) {
        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitForExistence(timeout: 20), "The result must expose its view modes")
        let structure = modePicker.radioButtons["Structure"].firstMatch
        XCTAssertTrue(structure.waitForExistence(timeout: 20), "Structure must be one of them")
        structure.click()
    }

    /// The sub-tab labels carry item counts, so they are matched by prefix rather than exactly.
    private func subTab(named name: String, in window: XCUIElement) -> XCUIElement {
        window.radioGroups["structure-tab-picker"].firstMatch
            .radioButtons
            .matching(NSPredicate(format: "label BEGINSWITH %@", name))
            .firstMatch
    }
}
