//
//  ConnectionTagEditorUITests.swift
//  TableProUITests
//
//  "Add tags" used to be a label sitting beside the control rather than being the control, so the
//  words did nothing and only the chevron opened the menu. It is now the pull-down's own title,
//  which is what every macOS pull-down does with its placeholder. Clicking the words has to open
//  the menu, and that is what this covers.
//

import XCTest

final class ConnectionTagEditorUITests: UITestCase {
    private let tagMenu = "connection-form-tags"

    func testTheAddTagsPlaceholderOpensTheTagMenu() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "SQLite", in: app)
        selectTab("appearance", in: form)

        let menu = form.descendants(matching: .any).matching(identifier: tagMenu).firstMatch
        XCTAssertTrue(menu.waitToExist(timeout: 10), "The Appearance tab should offer a Tags control")
        XCTAssertTrue(waitUntilHittable(menu, timeout: 10))

        /// The placeholder's width is what says it is inside the control rather than beside it, and
        /// width is the only thing that says it: a SwiftUI `Menu` is an `NSPopUpButton`, whose label
        /// no suite has ever resolved, and the identifier reaches a wrapper that carries no name.
        /// Measured, the control is 79pt wide titled "Add tags" and 24pt wide with an empty label,
        /// so the threshold sits well clear of both.
        XCTAssertGreaterThan(
            menu.frame.width,
            40,
            "With no tag chosen the placeholder is the control's own title, so the words are part of it"
        )

        menu.click()
        XCTAssertTrue(
            form.menus.firstMatch.waitToExist(timeout: 5),
            "Clicking the Add tags control should open its menu"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    func testTheTagMenuOffersCreatingATag() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "SQLite", in: app)
        selectTab("appearance", in: form)

        let menu = form.descendants(matching: .any).matching(identifier: tagMenu).firstMatch
        XCTAssertTrue(menu.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(menu, timeout: 10))
        menu.click()

        XCTAssertTrue(
            form.menus.firstMatch.menuItems["Create New Tag…"].waitToExist(timeout: 5),
            "A connection with no tags yet still needs a route to making one"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    private func selectTab(_ tab: String, in form: XCUIElement) {
        let row = form.descendants(matching: .any)
            .matching(identifier: "connection-form-section-\(tab)")
            .firstMatch
        XCTAssertTrue(
            row.waitToExist(timeout: 10),
            "No sidebar row identified connection-form-section-\(tab)"
        )
        XCTAssertTrue(waitUntilHittable(row, timeout: 10))
        row.click()
    }

    /// Scoped to the sheet, not the app: the welcome window behind it owns a `sidebar-filter`
    /// search field that `app.searchFields.firstMatch` reaches first.
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
