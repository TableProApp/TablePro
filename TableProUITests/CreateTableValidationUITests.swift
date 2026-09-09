//
//  CreateTableValidationUITests.swift
//  TableProUITests
//
//  The Create Table tab says why it cannot run and dims the button, instead of dropping the rows it
//  could not use. A foreign key with no constraint name used to be deleted from the generated
//  statement with no message at all, and the SQL Preview agreed with the deletion.
//
//  The grids themselves are out of reach here: a data grid cell is drawn with CoreText and takes no
//  synthetic click, so the round trip from a filled foreign key row to a FOREIGN KEY clause is
//  covered by CreateTableDraftBuilderTests and SQLiteCreateTableDDLTests instead.
//
//  Every element is addressed by identifier. `window.buttons["Create Table"].firstMatch` matches the
//  editor tab of that name before it reaches the button, and it reports itself enabled.
//
//  The reason's text per draft state is asserted in CreateTableDraftBuilderTests rather than here:
//  driving it needs typed text to reach a SwiftUI TextField's binding, which does not land through
//  XCUITest reliably enough to gate a branch on.
//

import XCTest

final class CreateTableValidationUITests: UITestCase {
    func testAnEmptyDraftNamesWhatIsMissingAndDimsCreateTable() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        try openNewTableTab(in: app, window: window)

        let reason = validationLabel(in: window)
        XCTAssertTrue(
            reason.waitToExist(timeout: 30),
            "A Create Table tab that cannot run yet must say so. Silence is what let a filled-in "
                + "foreign key vanish between the grid and the SQL Preview."
        )

        let commit = window.buttons["create-table-commit"].firstMatch
        XCTAssertTrue(commit.waitToExist(timeout: 10), "The tab must carry a Create Table button")
        XCTAssertFalse(
            commit.isEnabled,
            "An empty draft has no table name and no column, so Create Table stays dimmed"
        )
    }

    private func validationLabel(in window: XCUIElement) -> XCUIElement {
        window.staticTexts.matching(identifier: "create-table-validation").firstMatch
    }

    private func openNewTableTab(in app: XCUIApplication, window: XCUIElement) throws {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 20))
        menuBar.menuBarItems["Database"].click()

        let newTable = menuBar.menuItems["New Table…"]
        XCTAssertTrue(newTable.waitToExist(timeout: 10), "Database > New Table… must be reachable")
        newTable.click()
    }

    private func mainWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        return window
    }
}
