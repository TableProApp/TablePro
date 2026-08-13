import XCTest

final class QuickSwitcherCrossConnectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    func testConnectionsScopeSearchesTheOpenSampleDatabase() throws {
        let app = launchWithSampleDatabase()
        XCTAssertTrue(editorTextView(in: app).waitForExistence(timeout: 15))

        app.typeKey("o", modifierFlags: [.command, .shift])
        let searchField = app.textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))

        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Connections"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Chinook (Sample)"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Track"].waitForExistence(timeout: 5))

        searchField.typeText("track")
        XCTAssertTrue(app.staticTexts["Track"].waitForExistence(timeout: 5))

        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText("missing-object-name")
        XCTAssertTrue(app.staticTexts["No results for \"missing-object-name\""].waitForExistence(timeout: 5))

        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText("track")
        searchField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        let trackWindow = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Track")).firstMatch
        XCTAssertTrue(trackWindow.waitForExistence(timeout: 10))

        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        app.typeKey("5", modifierFlags: .command)
        searchField.typeText("invoice")
        searchField.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        let invoiceWindow = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Invoice")).firstMatch
        XCTAssertTrue(invoiceWindow.waitForExistence(timeout: 10))

        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("dismiss-me")
        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "The first Escape clears the query, it does not dismiss")
        XCTAssertEqual(searchField.value as? String, "")
        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
    }

    func testQueriesScopeSearchesHistoryAndOpensANewWindowTab() throws {
        let app = launchWithSampleDatabase()
        XCTAssertTrue(editorTextView(in: app).waitForExistence(timeout: 15))

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitForExistence(timeout: 10))
        let query = "SELECT 42 AS cross_connection_probe;"
        queryEditor.click()
        app.typeText(query)
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.tables.firstMatch.waitForExistence(timeout: 15))
        queryEditor.click()
        queryEditor.typeKey("a", modifierFlags: .command)
        queryEditor.typeText("SELECT 0;")

        app.typeKey("o", modifierFlags: [.command, .shift])
        let searchField = app.textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Queries"].waitForExistence(timeout: 5))

        searchField.typeText("cross_connection_probe")
        let historyResult = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "cross_connection_probe")
        ).firstMatch
        XCTAssertTrue(historyResult.waitForExistence(timeout: 10))

        searchField.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        let openedEditor = app.textViews.matching(identifier: "sql-editor-textview")
            .matching(NSPredicate(format: "value == %@", query))
            .firstMatch
        XCTAssertTrue(openedEditor.waitForExistence(timeout: 10))
    }

    private func launchWithSampleDatabase() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 10))
        menuBar.menuBarItems["Help"].click()
        let openSample = menuBar.menuItems["Open Sample Database"]
        XCTAssertTrue(openSample.waitForExistence(timeout: 5))
        openSample.click()
        return app
    }

    private func editorTextView(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let identified = window.textViews.matching(identifier: "sql-editor-textview").firstMatch
        if identified.exists {
            return identified
        }
        return window.textViews.firstMatch
    }
}
