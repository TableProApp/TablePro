import XCTest

/// A database file that does not exist yet is created on connect, and the form used to offer only
/// an open panel, which has no name field. New… names the file in a save panel and records the path;
/// nothing is written until the connection opens. SQLite drives it because it ships in the app.
final class ConnectionFormDatabaseFileUITests: UITestCase {
    private let filePath = "connection-form-file-path"
    private let browseButton = "connection-form-file-browse"
    private let newButton = "connection-form-file-new"
    /// AppKit's own identifier for the save panel's name field, as the runner's element tree shows it.
    private let saveAsNameField = "saveAsNameTextField"

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

        let panel = readySavePanel(on: form)
        let create = panel.buttons["Create"]
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { create.exists && create.isEnabled },
            "A name that does not exist yet should leave Create enabled"
        )
        create.click()

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

        let panel = readySavePanel(on: form)
        panel.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(waitForPredicate(timeout: 10) { !form.sheets.firstMatch.exists })
        XCTAssertEqual(field.value as? String, typed)
    }

    // MARK: - Helpers

    /// The save panel New… opens, once it takes input.
    ///
    /// The sheet is in the accessibility tree before the panel can take a key or a click. The runner's
    /// screen recordings in run 37204198338 show it arrive in three steps: on screen with Create dimmed,
    /// then Create enabled, then, about a quarter of a second after it appeared, key, with the name
    /// selected in its field and Create turned blue. A Return sent as soon as the sheet existed fell
    /// into that gap and nothing took it: both attempts left the panel open, Create enabled and the
    /// name typed, until the wait for it to close ran out. The runs that passed did so only because
    /// XCTest's wait for the app to go idle after the New… click happened to outlast the panel's setup.
    ///
    /// The name field takes the keyboard in the same moment the panel becomes key, so waiting for that
    /// waits for the panel to be ready. Nothing in the app can close the gap: making the sheet key once
    /// it is presented is AppKit's own sequence.
    private func readySavePanel(on form: XCUIElement) -> XCUIElement {
        let panel = form.sheets.firstMatch
        XCTAssertTrue(panel.waitToExist(timeout: 10), "New… should open a save panel on the form")
        let nameField = panel.textFields[saveAsNameField]
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { holdsKeyboardFocus(nameField) },
            "The save panel should become key with the keyboard in its name field"
        )
        return panel
    }

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
