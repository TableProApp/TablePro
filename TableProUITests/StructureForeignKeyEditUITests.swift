//
//  StructureForeignKeyEditUITests.swift
//  TableProUITests
//

import XCTest

/// The reported defect end to end. Adding a foreign key on SQLite used to reach the DDL generator
/// and come back as "Unsupported schema operation: Add foreign key ''": the "+" was offered on
/// every engine that *has* foreign keys rather than every engine that can edit them, and Save never
/// consulted the validation that would have caught the blank row.
final class StructureForeignKeyEditUITests: UITestCase {
    /// SQLite is curated as rebuilding the table for a foreign key change, so the pair under the
    /// list has to be live. A regression in that curated value would silently take the whole
    /// feature away without failing a unit test that never reads the registry.
    func testAddForeignKeyIsOfferedOnSQLite() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        try openForeignKeysTab(app: app, window: window)

        let add = window.buttons["structure-footer-add"].firstMatch
        XCTAssertTrue(add.waitToExist(timeout: 20), "The Foreign Keys tab must offer an add button")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { add.isEnabled },
            "SQLite rebuilds the table to change a foreign key, so adding one must be offered"
        )
    }

    /// The "+" stages a blank row immediately. Saving it used to build
    /// `ADD CONSTRAINT "" FOREIGN KEY () REFERENCES "" ()`; now the save is refused and says which
    /// row is incomplete, with the edit left staged.
    func testSavingABlankForeignKeyIsRefusedWithAReason() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        try openForeignKeysTab(app: app, window: window)

        let add = window.buttons["structure-footer-add"].firstMatch
        XCTAssertTrue(add.waitToExist(timeout: 20))
        XCTAssertTrue(waitForPredicate(timeout: 10) { add.isEnabled })
        add.click()

        app.typeKey("s", modifierFlags: .command)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 20), "An incomplete foreign key must stop the save")

        /// `value`, not `label`. An `NSAlert`'s messageText and informativeText reach XCUITest as the
        /// static text's value and leave its label empty, so reading the label alone found the right
        /// sheet and reported it as blank.
        let text = sheet.staticTexts.allElementsBoundByIndex
            .map { ($0.value as? String) ?? $0.label }
            .joined(separator: " ")
        XCTAssertFalse(
            text.contains("Unsupported schema operation"),
            "The blank row must be refused by validation, not by the DDL generator"
        )
        XCTAssertTrue(
            text.contains("Foreign key"),
            "The refusal must name the row that is incomplete, got: \(text)"
        )
    }

    private func openForeignKeysTab(app: XCUIApplication, window: XCUIElement) throws {
        let row = objectBrowserRow("Album", in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        showStructure(in: app, window: window)

        /// The sub-tab labels carry item counts, so they are matched by prefix rather than exactly.
        let foreignKeys = window.radioGroups["structure-tab-picker"].firstMatch
            .radioButtons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Foreign Keys"))
            .firstMatch
        XCTAssertTrue(foreignKeys.waitToExist(timeout: 20), "SQLite has foreign keys, so the tab must be offered")
        foreignKeys.click()
    }
}
