import XCTest

final class NewConnectionCommandUITests: UITestCase {
    func testCommandNWithNoWindowCreatesAndConnectsANewSQLiteFile() throws {
        let root = try XCTUnwrap(sandboxRoot)
        let fileName = "scratch.sqlite"
        let databaseURL = root.appendingPathComponent(fileName)

        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 10))
        app.typeShortcut(.closeTab)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !welcome.exists },
            "The welcome window must close: New Connection used to break with no window open"
        )

        app.typeShortcut(.newConnection)
        let chooser = welcome.sheets.firstMatch
        XCTAssertTrue(chooser.waitToExist(timeout: 10), "New Connection must present the database chooser")
        let search = chooser.searchFields["database-type-chooser-search"]
        XCTAssertTrue(waitUntilHittable(search, timeout: 10), "The chooser must offer its search field")
        search.click()
        search.typeText("SQLite")
        let proceed = chooser.buttons["Continue"]
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { proceed.exists && proceed.isEnabled },
            "An exact type name must arm Continue"
        )
        proceed.click()

        let form = window("connection-form", in: app)
        XCTAssertTrue(form.waitToExist(timeout: 10), "Choosing SQLite must open the connection form")
        replaceText(in: form.textFields["connection-form-name"], with: "Scratch")
        let path = form.textFields["connection-form-file-path"]
        replaceText(in: path, with: databaseURL.path)

        let new = form.buttons["connection-form-file-new"]
        XCTAssertTrue(waitUntilHittable(new, timeout: 10), "SQLite creates a missing file, so New… must be offered")
        new.click()
        let panel = form.sheets.firstMatch
        XCTAssertTrue(panel.waitToExist(timeout: 10), "New… must open a save panel on the form")
        // The sheet is in the tree before it takes input; its name field taking the keyboard is the signal.
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.holdsKeyboardFocus(panel.textFields["saveAsNameTextField"]) },
            "The save panel must become key with the keyboard in its name field"
        )
        let create = panel.buttons["Create"]
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { create.exists && create.isEnabled },
            "A name that does not exist yet must leave Create enabled"
        )
        create.click()
        XCTAssertTrue(waitForPredicate(timeout: 10) { !panel.exists }, "Create must close the panel")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (path.value as? String)?.hasSuffix("/\(fileName)") == true },
            "The panel must put the named path back in the field"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: databaseURL.path),
            "New… only names the file; nothing is written before the connection opens"
        )

        let connect = form.buttons["Save & Connect"]
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { connect.exists && connect.isEnabled },
            "A named connection with a file path must be ready to connect"
        )
        connect.click()

        XCTAssertTrue(mainWindow(in: app).waitToExist(timeout: 30), "Save & Connect must open a connection window")
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { FileManager.default.fileExists(atPath: databaseURL.path) },
            "Connecting must create the database file"
        )
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(waitUntilHittable(field, timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }
}
