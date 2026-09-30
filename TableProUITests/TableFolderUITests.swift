import XCTest

/// Issue #3167. Tables and views can be filed into folders from the object browser's own menu, a
/// new folder is named in its row, and deleting a folder puts its tables back and can be undone.
///
/// The sample database is SQLite in the flat layout, so the tree layout and drag and drop are not
/// exercised here. Their rules are asserted without a window in `TableFolderPlannerTests`,
/// `TableFolderDropResolverTests` and `DatabaseTreeMenuSpecTests`.
final class TableFolderUITests: UITestCase {
    func testMovingATableIntoANewFolderNamesTheFolderInItsRow() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        fileIntoNewFolder("Album", named: "Music", in: window, of: app)

        XCTAssertTrue(
            folderRow("Music", in: window).waitToExist(timeout: 20),
            "The folder must appear under the name typed into its row"
        )
        XCTAssertTrue(
            objectBrowserRow("Album", in: window).waitToExist(timeout: 10),
            "The table must still be listed, now inside the folder"
        )
    }

    func testDeletingAFolderKeepsItsTablesAndUndoBringsItBack() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        fileIntoNewFolder("Album", named: "Music", in: window, of: app)
        let folder = folderRow("Music", in: window)
        XCTAssertTrue(folder.waitToExist(timeout: 20))

        folder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let delete = window.menus.menuItems["Delete Folder"].firstMatch
        XCTAssertTrue(delete.waitToExist(timeout: 15), "A folder row must offer Delete Folder")
        XCTAssertTrue(waitUntilHittable(delete, timeout: 10))
        delete.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !folder.exists },
            "Delete Folder must remove the folder without asking, since nothing leaves the database"
        )
        XCTAssertTrue(
            objectBrowserRow("Album", in: window).waitToExist(timeout: 10),
            "The table the folder held must go back to its section"
        )

        app.typeKey("z", modifierFlags: .command)

        XCTAssertTrue(
            folderRow("Music", in: window).waitToExist(timeout: 20),
            "Undo must bring the deleted folder back"
        )
    }

    // MARK: - Helpers

    private func fileIntoNewFolder(
        _ table: String,
        named name: String,
        in window: XCUIElement,
        of app: XCUIApplication
    ) {
        let row = objectBrowserRow(table, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(table)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

        let moveTo = window.menus.menuItems["Move to"].firstMatch
        XCTAssertTrue(moveTo.waitToExist(timeout: 15), "A table row must offer Move to")
        moveTo.hover()

        let newFolderItems = app.menuItems.matching(NSPredicate(format: "title == %@", "New Folder"))
        var newFolder: XCUIElement?
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                newFolder = newFolderItems.allElementsBoundByIndex.first { $0.isHittable }
                return newFolder != nil
            },
            "Move to must offer New Folder"
        )
        newFolder?.click()

        let field = window.textFields.matching(identifier: "database-tree-rename-field").firstMatch
        XCTAssertTrue(field.waitToExist(timeout: 20), "A new folder must open with its name field")
        app.typeKey("a", modifierFlags: .command)
        app.typeText(name)
        app.typeKey(.return, modifierFlags: [])
    }

    /// Matched on the start of the value, because the row reads its item count after the name.
    private func folderRow(_ name: String, in window: XCUIElement) -> XCUIElement {
        window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Folder: \(name),"))
            .firstMatch
    }

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }
}
