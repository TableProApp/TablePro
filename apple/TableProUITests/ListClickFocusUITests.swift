import XCTest

final class ListClickFocusUITests: UITestCase {
    func testClickingASectionGivesTheListTheArrowKeys() throws {
        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        app.typeShortcut(.newConnection)
        let chooser = welcome.sheets.firstMatch
        let search = chooser.searchFields["database-type-chooser-search"]
        XCTAssertTrue(waitUntilHittable(search, timeout: 10), "New Connection must present the database chooser")
        search.click()
        search.typeText("SQLite")
        let proceed = chooser.buttons["Continue"]
        XCTAssertTrue(waitForPredicate(timeout: 10) { proceed.exists && proceed.isEnabled })
        proceed.click()

        let form = window("connection-form", in: app)
        XCTAssertTrue(form.waitToExist(timeout: 10), "Choosing SQLite must open the connection form")
        let name = form.textFields["connection-form-name"]
        XCTAssertTrue(waitUntilHittable(name, timeout: 10))
        name.click()

        let sidebar = form.outlines.containing(.staticText, identifier: "connection-form-section-options").firstMatch
        let optionsRow = sidebar.outlineRows.containing(.staticText, identifier: "connection-form-section-options").firstMatch
        let options = optionsRow.staticTexts["connection-form-section-options"]
        XCTAssertTrue(waitUntilHittable(options, timeout: 10))
        options.click()
        XCTAssertTrue(waitForPredicate(timeout: 10) { optionsRow.isSelected }, "Clicking Options must select it")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.holdsKeyboardFocus(sidebar) },
            "Clicking a section must move the keyboard from the name field to the list"
        )

        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !optionsRow.isSelected },
            "Up after clicking a section must select the section above it"
        )
    }
}
