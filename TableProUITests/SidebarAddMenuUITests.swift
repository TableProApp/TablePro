//
//  SidebarAddMenuUITests.swift
//  TableProUITests
//

import XCTest

// Item queries are scoped to the button: the Database menu carries the same titles.

final class SidebarAddMenuUITests: UITestCase {
    func testTheAddButtonOpensANewTable() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)

        let add = window.descendants(matching: .any).matching(identifier: "sidebar-add").firstMatch
        XCTAssertTrue(add.waitToExist(timeout: 30), "The Tables tab carries an add button at its foot")
        add.click()

        let newTable = add.menuItems["New Table…"].firstMatch
        XCTAssertTrue(newTable.waitToExist(timeout: 10), "The add button offers New Table…")
        XCTAssertTrue(newTable.isEnabled, "A writable SQLite connection can create a table")
        XCTAssertTrue(add.menuItems["New Folder"].firstMatch.exists, "The flat list offers New Folder")
        newTable.click()

        XCTAssertTrue(
            window.buttons["create-table-commit"].firstMatch.waitToExist(timeout: 30),
            "New Table… from the add button opens the Create Table tab"
        )
    }

    func testTheFavoritesAddButtonOffersTheFavoritesCommands() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        showFavorites(in: app)

        let add = window.descendants(matching: .any).matching(identifier: "sidebar-favorites-add").firstMatch
        XCTAssertTrue(add.waitToExist(timeout: 30), "The Favorites tab carries its own add button")
        add.click()

        for title in ["New Query", "New Favorite…", "New Folder", "Add Linked SQL Folder…"] {
            XCTAssertTrue(add.menuItems[title].firstMatch.waitToExist(timeout: 10), "Favorites add offers \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    private func showFavorites(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()

        let showFavorites = menuBar.menuItems["Show Favorites"]
        XCTAssertTrue(showFavorites.waitToExist(timeout: 5), "View > Show Favorites must be reachable")
        showFavorites.click()
    }

    private func mainWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        return window
    }
}
