import AppKit
import XCTest

/// Issue #2505. Editing a saved query keeps the SQL it replaced, Show History lists it, and
/// Restore This Version puts it back while keeping the text it replaced as another version.
final class SavedQueryHistoryUITests: UITestCase {
    func testAnEditedSavedQueryCanBeRestoredFromItsHistory() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        showFavorites(in: app)

        let newFavorite = window.buttons["New Favorite…"]
        XCTAssertTrue(newFavorite.waitToExist(timeout: 15), "The empty Favorites tab offers New Favorite…")
        newFavorite.click()
        fillFavoriteSheet(in: app, name: "Revenue", query: "SELECT 1", confirm: "Add")

        let row = window.outlines.staticTexts["Revenue"]
        XCTAssertTrue(row.waitToExist(timeout: 15), "The new saved query appears in the sidebar")
        row.rightClick()
        let edit = contextMenuItem("Edit…", in: app)
        XCTAssertTrue(edit.waitToExist(timeout: 5))
        edit.click()
        fillFavoriteSheet(in: app, name: nil, query: "SELECT 2", confirm: "Save")

        XCTAssertTrue(row.waitToExist(timeout: 10))
        row.rightClick()
        let showHistory = contextMenuItem("Show History", in: app)
        XCTAssertTrue(showHistory.waitToExist(timeout: 5), "A saved query's menu offers Show History")
        showHistory.click()

        let versions = window.tables["version-history-list"]
        XCTAssertTrue(versions.waitToExist(timeout: 15), "Show History opens the history tab")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { versions.tableRows.count == 2 },
            "The current version and the SQL the edit replaced"
        )

        versions.tableRows.element(boundBy: 1).click()
        let restore = window.buttons["version-history-restore"]
        XCTAssertTrue(waitForPredicate(timeout: 10) { restore.isEnabled }, "An earlier version can be restored")
        restore.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { versions.tableRows.count == 3 },
            "Restoring keeps the SQL it replaced as another version"
        )
    }

    private func fillFavoriteSheet(in app: XCUIApplication, name: String?, query: String, confirm: String) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "The saved query sheet opens")
        if let name {
            let nameField = sheet.textFields.firstMatch
            XCTAssertTrue(nameField.waitToExist(timeout: 5))
            nameField.click()
            nameField.typeText(name)
        }
        let queryEditor = sheet.textViews.firstMatch
        XCTAssertTrue(queryEditor.waitToExist(timeout: 5))
        queryEditor.click()
        queryEditor.typeKey("a", modifierFlags: .command)
        queryEditor.typeText(query)
        let confirmButton = sheet.buttons[confirm]
        XCTAssertTrue(waitForPredicate(timeout: 5) { confirmButton.isEnabled })
        confirmButton.click()
        XCTAssertTrue(waitForPredicate(timeout: 10) { !sheet.exists }, "The sheet closes after \(confirm)")
    }

    private func showFavorites(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()
        let showFavorites = menuBar.menuItems["Show Favorites"]
        XCTAssertTrue(showFavorites.waitToExist(timeout: 5), "View > Show Favorites must be reachable")
        showFavorites.click()
    }
}
