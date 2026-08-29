//
//  StructurePropertiesTabUITests.swift
//  TableProUITests
//

import XCTest

final class StructurePropertiesTabUITests: UITestCase {
    /// Properties is the first segment of the picker, so the failure it guards against is the whole
    /// tab missing or landing somewhere else in the run.
    func testPropertiesTabIsFirstAndOpens() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let row = objectBrowserRow("Album", in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        showStructure(in: window)

        let picker = window.radioGroups["structure-tab-picker"].firstMatch
        XCTAssertTrue(picker.waitToExist(timeout: 20), "The structure editor must offer its sub-tabs")

        let properties = subTab(named: "Properties", in: window)
        XCTAssertTrue(properties.waitToExist(timeout: 20), "Properties must reach the picker")
        XCTAssertEqual(
            picker.radioButtons.firstMatch.label,
            properties.label,
            "Properties is the leading segment"
        )

        properties.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { isSelected(properties) },
            "Selecting Properties moves the picker to it"
        )

        XCTAssertTrue(
            window.staticTexts["Album"].waitToExist(timeout: 20),
            "The Properties tab names the table it was opened on"
        )
    }

    /// SQLite stores no comment on a table, which is what makes it the deterministic case: the field
    /// must not offer an edit that no statement can carry.
    func testCommentIsReadOnlyWhereTheEngineHasNone() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let row = objectBrowserRow("Album", in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        showStructure(in: window)

        let properties = subTab(named: "Properties", in: window)
        XCTAssertTrue(properties.waitToExist(timeout: 20), "Properties must reach the picker")
        properties.click()

        XCTAssertTrue(
            window.staticTexts["This database does not store a comment on a table."]
                .waitToExist(timeout: 20),
            "SQLite has no table comment, so the field reports that instead of offering an editor"
        )
        XCTAssertFalse(
            window.textViews["table-comment-editor"].exists,
            "No comment editor is mounted where the engine has no comment to write"
        )
    }

    /// A radio button in a hosted picker reports `AXSelected` as nil and answers with `AXValue`
    /// instead, so `isSelected` reads as false however the picker is set.
    private func isSelected(_ segment: XCUIElement) -> Bool {
        (segment.value as? NSNumber)?.intValue == 1
    }

    private func showStructure(in window: XCUIElement) {
        let modePicker = window.radioGroups["results-view-mode-picker"].firstMatch
        XCTAssertTrue(modePicker.waitToExist(timeout: 20), "The result must expose its view modes")
        let structure = modePicker.radioButtons["Structure"].firstMatch
        XCTAssertTrue(structure.waitToExist(timeout: 20), "Structure must be one of them")
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
