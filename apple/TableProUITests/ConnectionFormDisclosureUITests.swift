import XCTest

final class ConnectionFormDisclosureUITests: UITestCase {
    /// The connection editor is one scrolling form, and its rarely-set options stay behind a
    /// disclosure so a plain connection is not a wall of controls.
    ///
    /// The revealed controls render at the end of the scrolling form where the grouped `Form`
    /// virtualizes them off the fold, so XCUITest cannot read them, and a SwiftUI button does not
    /// surface `accessibilityValue` through `XCUIElement.value`. This asserts the two facts the
    /// accessibility tree does expose: the options are collapsed by default and the disclosure that
    /// gates them is present and usable. The reveal itself is covered by the revamp PR's screenshots.
    func testAdvancedOptionsStartCollapsedBehindADisclosure() throws {
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
        XCTAssertTrue(waitUntilHittable(name, timeout: 10), "The form opens on a single scrolling layout with a Name field")

        let connectTimeout = form.textFields["connection-form-connect-timeout"]
        XCTAssertFalse(connectTimeout.exists, "Advanced options are collapsed by default")

        let disclosure = form.descendants(matching: .any)["connection-form-advanced-disclosure"]
        XCTAssertTrue(waitUntilHittable(disclosure, timeout: 10), "The form shows an Advanced Options disclosure")
    }
}
