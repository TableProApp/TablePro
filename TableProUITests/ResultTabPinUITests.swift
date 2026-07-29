//
//  ResultTabPinUITests.swift
//  TableProUITests
//
//  Covers #1982: pinning a query result must be reachable from the result tab itself.
//  The query is padded past the height of the editor pane because that is what used to
//  make the editor claim right-clicks over the results.
//

import XCTest

final class ResultTabPinUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    func testResultTabExposesPinButtonAndPinMenuItem() throws {
        let app = launchWithSampleDatabase()

        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 15))

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitForExistence(timeout: 10))
        queryEditor.click()
        app.typeText(paddedQuery)
        app.typeKey(.return, modifierFlags: .command)

        let resultTab = app.buttons["result-tab"].firstMatch
        XCTAssertTrue(resultTab.waitForExistence(timeout: 20), "The query must produce a result tab")
        resultTab.rightClick()

        let contextMenu = app.menus.firstMatch
        XCTAssertTrue(
            contextMenu.menuItems["Close Others"].waitForExistence(timeout: 5),
            "Right-clicking a result tab must open the result menu, not the editor menu"
        )
        contextMenu.menuItems["Pin Result"].click()

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["View"].click()
        let unpinItem = menuBar.menuItems["Unpin Result"]
        XCTAssertTrue(unpinItem.waitForExistence(timeout: 5), "A pinned result reads as Unpin Result")
        XCTAssertTrue(unpinItem.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    private var paddedQuery: String {
        let padding = (1...60).map { "-- line \($0)" }.joined(separator: "\n")
        return "\(padding)\nSELECT 1;"
    }

    private func launchWithSampleDatabase() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 10))
        menuBar.menuBarItems["File"].click()
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
