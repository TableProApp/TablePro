//
//  ConnectionIconPickerUITests.swift
//  TableProUITests
//
//  The connection list draws the tile as decoration, hidden from accessibility, so the icon is read
//  back through the form the list's Edit… opens, which loads the stored connection.
//

import XCTest

final class ConnectionIconPickerUITests: UITestCase {
    private let well = "connection-form-icon"
    private let search = "symbol-picker-search"

    func testAnIconPickedInTheAppearancePaneReachesTheConnectionList() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "PostgreSQL", in: app)
        let name = form.textFields["connection-form-name"]
        XCTAssertTrue(name.waitToExist(timeout: 10))
        name.click()
        name.typeText("Icon probe")

        selectConnectionFormTab("appearance", in: form)
        let iconWell = form.buttons[well]
        XCTAssertTrue(iconWell.waitToExist(timeout: 10), "The Appearance tab should offer an Icon control")
        XCTAssertEqual(iconWell.value as? String, "Default", "A new connection starts on the engine's icon")
        XCTAssertTrue(waitUntilHittable(iconWell, timeout: 10))
        iconWell.click()

        let searchField = app.searchFields[search]
        XCTAssertTrue(searchField.waitToExist(timeout: 5), "The icon control should open the picker")
        XCTAssertTrue(waitUntilHittable(searchField, timeout: 5))
        searchField.click()
        searchField.typeText("Server")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (searchField.value as? String) == "Server" },
            "Typing should reach the picker's search field"
        )
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5), "Return should pick the match and close the picker")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (iconWell.value as? String) == "Server" },
            "The picked icon should show in the form"
        )

        let save = form.buttons["Save"]
        XCTAssertTrue(waitUntilHittable(save, timeout: 10))
        save.click()
        XCTAssertTrue(waitForPredicate(timeout: 15) { !form.exists }, "Save should close the form")

        let list = app.windows["welcome"].outlines["welcome-connection-list"]
        let saved = list.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Icon probe"))
            .firstMatch
        XCTAssertTrue(saved.waitToExist(timeout: 15), "The saved connection should appear in the welcome list")
        XCTAssertTrue(waitUntilHittable(saved, timeout: 10))
        saved.rightClick()
        let edit = contextMenuItem("Edit…", in: app)
        XCTAssertTrue(waitUntilHittable(edit, timeout: 5))
        edit.click()

        let reopened = app.windows["connection-form"]
        XCTAssertTrue(reopened.waitToExist(timeout: 10), "Edit should reopen the saved connection")
        selectConnectionFormTab("appearance", in: reopened)
        let reopenedWell = reopened.buttons[well]
        XCTAssertTrue(reopenedWell.waitToExist(timeout: 10))
        XCTAssertEqual(reopenedWell.value as? String, "Server", "The list's connection should carry the picked icon")
    }

    private func openConnectionForm(for type: String, in app: XCUIApplication) throws -> XCUIElement {
        let newConnection = app.menuBars.menuItems["New Connection…"]
        XCTAssertTrue(newConnection.waitToExist(timeout: 10))
        newConnection.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "New Connection… should open the chooser sheet")

        let chooserSearch = sheet.searchFields.firstMatch
        XCTAssertTrue(chooserSearch.waitToExist(timeout: 10), "The chooser should offer its search field")
        XCTAssertTrue(waitUntilHittable(chooserSearch, timeout: 10))
        chooserSearch.click()
        chooserSearch.typeText(type)

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
