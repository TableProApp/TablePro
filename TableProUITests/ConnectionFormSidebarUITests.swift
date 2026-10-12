import XCTest

final class ConnectionFormSidebarUITests: UITestCase {
    /// The sections are the form's only navigation and the titlebar has no sidebar button, so a
    /// sidebar dragged shut would leave the form stuck on one section.
    func testSidebarSurvivesADragToTheWindowEdge() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "PostgreSQL", in: app)
        let splitter = form.splitters.firstMatch
        XCTAssertTrue(splitter.waitToExist(timeout: 10), "The form should expose the sidebar divider")

        splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.3,
            thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        )

        selectConnectionFormTab("options", in: form)
        XCTAssertTrue(
            form.textFields["connection-form-connect-timeout"].waitToExist(timeout: 10),
            "A section should still be reachable from the sidebar after the drag"
        )
    }

    private func openConnectionForm(for type: String, in app: XCUIApplication) throws -> XCUIElement {
        let newConnection = app.menuBars.menuItems["New Connection…"]
        XCTAssertTrue(newConnection.waitToExist(timeout: 10))
        newConnection.click()

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
