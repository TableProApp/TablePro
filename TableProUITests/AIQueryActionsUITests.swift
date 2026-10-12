//
//  AIQueryActionsUITests.swift
//  TableProUITests
//

import XCTest

final class AIQueryActionsUITests: UITestCase {
    func testReviewIsOfferedButDimmedUntilAProviderIsAdded() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        typeQuery("SELECT * FROM albums;", in: app)

        let window = app.windows.firstMatch
        let review = window.descendants(matching: .any)
            .matching(identifier: "query-ai-review")
            .firstMatch
        XCTAssertTrue(review.waitToExist(timeout: 10), "The query bar must carry the Review with AI control")
        XCTAssertFalse(review.isEnabled, "With no AI provider the control must be dimmed, not act on nothing")

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Query"].click()
        let item = menuBar.menuItems["Review with AI"]
        XCTAssertTrue(item.waitToExist(timeout: 5), "Query > Review with AI must exist")
        XCTAssertFalse(item.isEnabled, "Query > Review with AI must be dimmed with no provider")
        XCTAssertTrue(menuBar.menuItems["Explain with AI"].exists)
        XCTAssertTrue(menuBar.menuItems["Optimize with AI"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testAIActionsMenuIsNamed() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let menu = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "query-ai-menu")
            .firstMatch
        XCTAssertTrue(menu.waitToExist(timeout: 10), "The query bar must carry the AI Actions menu")
        XCTAssertTrue(
            menu.label == "AI Actions" || menu.title == "AI Actions",
            "The AI menu must be named AI Actions: got label '\(menu.label)', title '\(menu.title)'"
        )
    }

    func testContextMenuHidesAIItemsItCannotRun() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        typeQuery("SELECT * FROM albums;", in: app)

        let editor = editorTextView(in: app)
        editor.rightClick()
        let menu = app.windows.firstMatch.menus.firstMatch
        XCTAssertTrue(menu.menuItems["Format SQL"].waitToExist(timeout: 5), "The editor's context menu must open")
        XCTAssertFalse(menu.menuItems["Review with AI"].exists, "An AI item that cannot run is hidden in a context menu")
        app.typeKey(.escape, modifierFlags: [])
    }
}
