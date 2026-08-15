import XCTest

/// The single-window model moved the editor tab commands off AppKit's own window-tab selectors
/// onto the app's tab list, and added the Window menu item the HIG requires once app windows
/// share a tabbing identifier. These are the parts of that contract a UI test can assert without
/// a live database.
final class SingleWindowMenuContractUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    /// Every app window now shares one tabbing identifier, so Merge All Windows is the documented
    /// route back to a single window. It was the one standard tab item the Window menu omitted.
    func testWindowMenuOffersMergeAllWindows() throws {
        let app = launchApp()

        let mergeAll = app.menuBars.menuItems["Merge All Windows"]
        XCTAssertTrue(
            mergeAll.waitForExistence(timeout: 5),
            "Window menu must offer Merge All Windows once app windows share a tabbing identifier"
        )
    }

    func testWindowMenuKeepsTheStandardTabCommands() throws {
        let app = launchApp()

        for title in ["Show Previous Tab", "Show Next Tab", "Move Tab to New Window"] {
            XCTAssertTrue(
                app.menuBars.menuItems[title].waitForExistence(timeout: 5),
                "Window menu must keep the standard tab command \(title)"
            )
        }
    }

    func testFileMenuOffersTheEditorTabCommands() throws {
        let app = launchApp()

        for title in ["New Tab", "Close Tab"] {
            XCTAssertTrue(
                app.menuBars.menuItems[title].waitForExistence(timeout: 5),
                "File menu must offer \(title), which now acts on the editor tab list"
            )
        }
    }

    /// The connections strip offers Close on a row, and the HIG requires every context-menu command
    /// to be reachable from the menu bar too.
    func testFileMenuOffersCloseConnection() throws {
        let app = launchApp()

        XCTAssertTrue(
            app.menuBars.menuItems["Close Connection"].waitForExistence(timeout: 5),
            "File menu must mirror the connections strip's Close command"
        )
    }

    /// The rail is named for what it lists. "Workspace" was a term the product invented for a
    /// window-like thing, which the HIG's Windows guidance rules out.
    func testViewMenuNamesTheConnectionsStrip() throws {
        let app = launchApp()

        XCTAssertTrue(
            app.menuBars.menuItems["Show Connections"].waitForExistence(timeout: 5),
            "View menu must name the strip after what it lists"
        )
        XCTAssertFalse(
            app.menuBars.menuItems["Show Workspace Rail"].exists,
            "The invented noun must be gone from the menu bar"
        )
    }

    /// Launching shows the welcome window and nothing else. A second main window appearing here
    /// is the shape of the bug the single-window model exists to prevent.
    func testLaunchOpensExactlyOneWindow() throws {
        let app = launchApp()

        XCTAssertEqual(
            app.windows.count,
            1,
            "Launch must open exactly one window, not one per restored connection"
        )
    }
}
