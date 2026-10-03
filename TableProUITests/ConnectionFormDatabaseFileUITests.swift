import XCTest

/// A database file that does not exist yet is created on connect, and the form used to offer only
/// an open panel, which has no name field. New… names the file in a save panel and records the path;
/// nothing is written until the connection opens. SQLite drives it because it ships in the app.
final class ConnectionFormDatabaseFileUITests: UITestCase {
    private let filePath = "connection-form-file-path"
    private let browseButton = "connection-form-file-browse"
    private let newButton = "connection-form-file-new"

    func testNewNamesADatabaseFileThatDoesNotExistYet() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "SQLite", in: app)
        let field = form.textFields[filePath]
        XCTAssertTrue(field.waitToExist(timeout: 10), "SQLite should offer a Database File field")
        XCTAssertTrue(form.buttons[browseButton].exists, "Browse… picks a file that exists")

        let name = "TablePro-UITest-\(UUID().uuidString).sqlite"
        replaceText(in: field, with: "/tmp/\(name)")

        let new = form.buttons[newButton]
        XCTAssertTrue(new.waitToExist(timeout: 5), "SQLite creates a missing file, so New… should be offered")
        XCTAssertTrue(waitUntilHittable(new, timeout: 10))
        new.click()

        let panel = form.sheets.firstMatch
        XCTAssertTrue(panel.waitToExist(timeout: 10), "New… should open a save panel on the form")
        panel.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !form.sheets.firstMatch.exists },
            "Create should close the panel"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (field.value as? String)?.hasSuffix("/\(name)") == true },
            "The panel should keep the name typed in the field and put its path back there"
        )
    }

    func testCancelingNewLeavesThePathAlone() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "SQLite", in: app)
        let field = form.textFields[filePath]
        XCTAssertTrue(field.waitToExist(timeout: 10))
        let typed = "/tmp/TablePro-UITest-\(UUID().uuidString).db"
        replaceText(in: field, with: typed)

        let new = form.buttons[newButton]
        XCTAssertTrue(waitUntilHittable(new, timeout: 10))
        new.click()

        let panel = form.sheets.firstMatch
        XCTAssertTrue(panel.waitToExist(timeout: 10))
        panel.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(waitForPredicate(timeout: 10) { !form.sheets.firstMatch.exists })
        XCTAssertEqual(field.value as? String, typed)
    }

    // MARK: - Helpers

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(waitUntilHittable(field, timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func openConnectionForm(for type: String, in app: XCUIApplication) throws -> XCUIElement {
        let newConnection = app.menuBars.menuItems["New Connection…"]
        XCTAssertTrue(newConnection.waitToExist(timeout: 10))
        newConnection.click()

        /// Scoped to the sheet: the welcome window behind it owns a search field of its own.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "New Connection… should open the chooser sheet")

        let search = sheet.searchFields.firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 10), "The chooser should offer its search field")
        XCTAssertTrue(waitUntilHittable(search, timeout: 10))
        search.click()
        search.typeText(type)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (search.value as? String) == type },
            "Typing should reach the chooser's search field"
        )

        let row = sheet.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", type))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 10), "The chooser should list \(type)")
        XCTAssertTrue(waitUntilHittable(row, timeout: 10))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        let form = app.windows["connection-form"]
        XCTAssertTrue(form.waitToExist(timeout: 10), "Choosing \(type) should open the connection form")
        return form
    }
}
