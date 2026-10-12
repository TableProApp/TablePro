import XCTest

/// The Extensions list is a connection field the app renders with its own editor, in its own
/// section of the Options tab, and only for the types whose plugin declares one. Nothing below the
/// view model proves the section reaches the screen for SQLite and stays off it for other engines,
/// so this drives the real form.
///
/// Adding a row goes through the system file panel, which a UI test cannot drive deterministically:
/// the panel's content types dim anything that is not a library and no library sits at a fixed path
/// on every runner. The list's own add, remove and reorder arithmetic is covered by
/// `LoadableExtensionListModelTests` instead.
final class LoadableExtensionListUITests: UITestCase {
    private let addButton = "connection-extensions-add"
    private let removeButton = "connection-extensions-remove"

    func testSQLiteOptionsOfferAnEmptyExtensionsList() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "SQLite", in: app)
        selectConnectionFormTab("options", in: form)

        let add = form.buttons[addButton]
        XCTAssertTrue(add.waitToExist(timeout: 10), "SQLite's Options tab should offer an Extensions list")
        XCTAssertEqual(add.label, "Add Extension…")
        XCTAssertTrue(add.isEnabled)

        let remove = form.buttons[removeButton]
        XCTAssertTrue(remove.exists)
        XCTAssertEqual(remove.label, "Remove Extension")
        XCTAssertFalse(remove.isEnabled, "Remove should be dimmed while nothing is selected")

        XCTAssertTrue(
            text("No Extensions", in: form).waitToExist(timeout: 5),
            "An empty list should say so"
        )
    }

    func testMySQLOptionsOfferNoExtensionsList() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "MySQL", in: app)
        selectConnectionFormTab("options", in: form)

        let startupCommands = form.descendants(matching: .any)
            .matching(identifier: "connection-form-startup-commands")
            .firstMatch
        XCTAssertTrue(startupCommands.waitToExist(timeout: 10), "The Options tab should have loaded")
        XCTAssertFalse(form.buttons[addButton].exists, "MySQL declares no extension list")
    }

    /// SwiftUI text carries its string in `value` with no label, so a subscript by title finds nothing.
    private func text(_ value: String, in form: XCUIElement) -> XCUIElement {
        form.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    private func openConnectionForm(for driver: String, in app: XCUIApplication) throws -> XCUIElement {
        let newConnection = app.menuBars.menuItems["New Connection…"]
        XCTAssertTrue(newConnection.waitToExist(timeout: 10))
        newConnection.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "New Connection… should open the chooser sheet")
        let search = sheet.searchFields.firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 10), "The chooser should offer its search field")
        XCTAssertTrue(waitUntilHittable(search, timeout: 10))
        search.click()
        search.typeText(driver)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (search.value as? String) == driver },
            "Typing should reach the chooser's search field"
        )

        let row = sheet.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", driver))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 10), "The chooser should list \(driver)")
        XCTAssertTrue(waitUntilHittable(row, timeout: 10))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        let form = app.windows["connection-form"]
        XCTAssertTrue(form.waitToExist(timeout: 10), "Choosing \(driver) should open the connection form")
        return form
    }
}
