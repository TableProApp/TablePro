import XCTest

/// The single-window model moved the editor tab commands off AppKit's own window-tab selectors
/// onto the app's tab list, and added the Window menu item the HIG requires once app windows
/// share a tabbing identifier. These are the parts of that contract a UI test can assert without
/// a live database.
final class SingleWindowMenuContractUITests: UITestCase {
    private func launchAppShowingAWindow() throws -> XCUIApplication {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))
        return app
    }

    /// Every app window now shares one tabbing identifier, so Merge All Windows is the documented
    /// route back to a single window. It was the one standard tab item the Window menu omitted.
    func testWindowMenuOffersMergeAllWindows() throws {
        let app = try launchAppShowingAWindow()

        let mergeAll = app.menuBars.menuItems["Merge All Windows"]
        XCTAssertTrue(
            mergeAll.waitToExist(timeout: 5),
            "Window menu must offer Merge All Windows once app windows share a tabbing identifier"
        )
    }

    func testWindowMenuKeepsTheStandardTabCommands() throws {
        let app = try launchAppShowingAWindow()

        for title in ["Show Previous Tab", "Show Next Tab", "Move Tab to New Window"] {
            XCTAssertTrue(
                app.menuBars.menuItems[title].waitToExist(timeout: 5),
                "Window menu must keep the standard tab command \(title)"
            )
        }
    }

    func testFileMenuOffersTheEditorTabCommands() throws {
        let app = try launchAppShowingAWindow()

        XCTAssertTrue(
            app.menuBars.menuItems["New Tab"].waitToExist(timeout: 5),
            "File menu must offer New Tab, which now acts on the editor tab list"
        )
    }

    /// Close is one item named after the window in front, the way Xcode, Terminal and Finder all
    /// ship it. Launch shows the welcome window, which has no tabs, so it reads Close Window.
    func testCloseIsNamedForTheKeyWindow() throws {
        let app = try launchAppShowingAWindow()

        XCTAssertTrue(
            app.menuBars.menuItems["Close Window"].waitToExist(timeout: 5),
            "A window with no tabs must name the close command Close Window"
        )
    }

    /// The retitle itself. "Close Window" is the title the menu is built with, so asserting only
    /// that would pass even if the title were never resolved from the key window.
    func testCloseIsNamedCloseTabOnceATabIsOpen() throws {
        let app = try launchWithSampleDatabase()
        app.typeKey("t", modifierFlags: .command)

        XCTAssertTrue(
            app.menuBars.menuItems["Close Tab"].waitToExist(timeout: 15),
            "A window with a tab open must name the close command Close Tab"
        )
        XCTAssertFalse(
            app.menuBars.menuItems["Close Window"].exists,
            "The close command is one item, so the built title must be gone once it resolves"
        )
    }

    /// The only test that reaches the sample database the way a person does. Every other suite asks
    /// for it at launch, because the menu route costs XCUITest a ten second failed traversal on
    /// every call, so the menu item itself would otherwise lose its coverage entirely.
    func testHelpMenuOpensTheSampleDatabase() throws {
        let app = try launchAndOpenSampleDatabaseFromHelpMenu()

        XCTAssertTrue(
            waitForSampleDatabaseWindow(in: app),
            "Help > Open Sample Database must open a connected window"
        )
    }

    /// The connections strip offers Close on a row, and the HIG requires every context-menu command
    /// to be reachable from the menu bar too.
    func testFileMenuOffersCloseConnection() throws {
        let app = try launchAppShowingAWindow()

        XCTAssertTrue(
            app.menuBars.menuItems["Close Connection"].waitToExist(timeout: 5),
            "File menu must mirror the connections strip's Close command"
        )
    }

    /// The rail is named for what it lists. "Workspace" was a term the product invented for a
    /// window-like thing, which the HIG's Windows guidance rules out.
    /// Either verb, because the item toggles with the strip's visibility and this is about the noun.
    /// Asserting only on "Show" made the test depend on how many connections happened to be
    /// restored at launch, which another suite could change out from under it.
    func testViewMenuNamesTheConnectionsStrip() throws {
        let app = try launchAppShowingAWindow()
        let menuItems = app.menuBars.menuItems

        XCTAssertTrue(
            menuItems["Show Connections"].waitToExist(timeout: 5)
                || menuItems["Hide Connections"].exists,
            "View menu must name the strip after what it lists"
        )
        XCTAssertFalse(menuItems["Show Workspace Rail"].exists, "The invented noun must be gone")
        XCTAssertFalse(menuItems["Hide Workspace Rail"].exists, "The invented noun must be gone")
    }

    /// Launching shows the welcome window and nothing else. A second main window appearing here
    /// is the shape of the bug the single-window model exists to prevent.
    func testLaunchOpensExactlyOneWindow() throws {
        let app = try launchAppShowingAWindow()

        XCTAssertEqual(
            app.windows.count,
            1,
            "Launch must open exactly one window, not one per restored connection"
        )
    }
}
