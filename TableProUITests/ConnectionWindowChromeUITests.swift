import AppKit
import XCTest

/// The window a user opens is the window they end up with.
///
/// A connection that is not up used to take the object browser off screen with it, along with the
/// filter field above it, so the window changed shape whenever the connection did. Disconnecting is
/// the deterministic way to reach that state: a connect fast enough to be reliable in a test is
/// also fast enough that no assertion can catch it mid-flight.
final class ConnectionWindowChromeUITests: UITestCase {
    func testDisconnectingLeavesTheSidebarWhereItWas() throws {
        let app = try launchWithSampleDatabase()

        let filterField = app.searchFields["sidebar-filter"]
        XCTAssertTrue(
            filterField.waitToExist(timeout: 30),
            "A connected window has a filter field above its object list"
        )

        disconnect(in: app)

        XCTAssertTrue(
            waitForDisconnect(in: app, timeout: 20),
            "Disconnect must end the session, or this asserts nothing"
        )
        XCTAssertTrue(
            filterField.exists,
            "Losing the session took the sidebar's chrome with it"
        )
    }

    /// Switch Connection is the window's own command and reaches no coordinator, so it is the one
    /// toolbar item that has to answer over a connection that is not up.
    func testTheToolbarSurvivesTheConnectionGoingAway() throws {
        let app = try launchWithSampleDatabase()

        let toolbar = app.windows.firstMatch.toolbars.firstMatch
        XCTAssertTrue(toolbar.waitToExist(timeout: 30), "A connection window has a toolbar")
        let itemsWhileConnected = toolbar.buttons.count

        disconnect(in: app)
        XCTAssertTrue(waitForDisconnect(in: app, timeout: 20))

        XCTAssertTrue(toolbar.exists, "Losing the session took the whole toolbar with it")
        XCTAssertEqual(
            toolbar.buttons.count,
            itemsWhileConnected,
            "Toolbar items are dimmed when a connection goes away, never removed"
        )
    }

    /// The regression test for the blank pane this change first shipped. A window whose chrome is
    /// stable but whose detail pane draws nothing is worse than the layout thrash it replaced, and
    /// nothing else here would catch it: every other assertion is about the chrome.
    ///
    /// `192.0.2.1` is TEST-NET-1, reserved for documentation, so it either swallows the SYN or is
    /// refused outright. Both are asserted, because the runner decides which: a card with Cancel
    /// while the connect is in flight, or the failure pane's own action once it is not. What is
    /// never acceptable is neither.
    func testTheDetailPaneNeverDrawsNothingWhileConnecting() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 20))

        try openProbeConnection(in: app)

        /// Each of these belongs to exactly one of the two panes that may legitimately be on
        /// screen. Asserting on buttons instead let the test pass over the blank pane it exists to
        /// catch, because a Cancel button elsewhere in the app satisfied it.
        XCTAssertTrue(
            waitForPredicate(timeout: 20) {
                app.staticTexts["Opening the connection"].exists
                    || app.staticTexts["Could not connect to Probe"].exists
                    || app.staticTexts["Not connected to Probe"].exists
            },
            "The detail pane drew nothing at all while the connection was being opened"
        )
        XCTAssertTrue(
            app.searchFields["sidebar-filter"].exists,
            "The sidebar's chrome has to stand through the whole of it"
        )
    }

    // MARK: - The toolbar's controls

    /// The default set is eight controls, and the ones the revamp took out stay out: no Browse and
    /// Agent segments, no Tables and Favorites segments, no Back and Forward pair.
    ///
    /// The sample is SQLite, which is file-based, so on macOS 15 and later the container capsule is
    /// the eighth control and is hidden: SQLite has one database and it is the file the connection
    /// capsule already names. Below 15 there is no `isHidden`, so the capsule stands and dims.
    func testTheDefaultToolbarCarriesItsControlsAndNoModeControl() throws {
        try skipUnlessTheScreenFitsThePinnedWindow()
        let app = try launchWithSampleDatabase(environment: pinnedEnvironment, arguments: englishArguments)
        let toolbar = try shownToolbar(of: connectionWindow(of: app), in: app)

        XCTAssertTrue(
            toolbar.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sidebar")).firstMatch
                .waitToExist(timeout: 20),
            "The sidebar toggle leads the default set"
        )
        for label in ["Connection", "Refresh", "Save Changes", "Inspector"] {
            XCTAssertTrue(toolbar.buttons[label].waitToExist(timeout: 10), "\(label) is in the default set")
        }
        for label in ["Actions", "Safe Mode"] {
            XCTAssertTrue(toolbar.menuButtons[label].waitToExist(timeout: 10), "\(label) is a pull-down in the default set")
        }

        let container = toolbar.buttons["Database"]
        if #available(macOS 15.0, *) {
            XCTAssertFalse(container.exists, "A file-based connection has no container to switch, so the capsule is hidden")
        } else {
            XCTAssertTrue(container.exists, "Below macOS 15 the container capsule stands and dims")
        }

        for label in ["Browse", "Agent", "Tables", "Favorites"] {
            XCTAssertFalse(
                toolbar.descendants(matching: .any)[label].exists,
                "\(label) moved out of the toolbar; it must not be drawn there"
            )
        }
        XCTAssertEqual(toolbar.radioGroups.count, 0, "The toolbar carries no segmented chooser at all")
        XCTAssertFalse(toolbar.buttons["Back"].exists, "Back and Forward are offered by Customize Toolbar, not the default set")
        XCTAssertFalse(toolbar.buttons["Forward"].exists)
    }

    /// The two sidebar lists are chosen from a control at the top of the sidebar, over the list it
    /// switches. The sample has no favorites, so the Favorites list settles on its empty state, and
    /// that state going away is what shows Tables took the sidebar back.
    func testTheSidebarScopeControlSwitchesTablesAndFavorites() throws {
        let app = try launchWithSampleDatabase(arguments: englishArguments)
        let window = try connectionWindow(of: app)

        let scope = window.radioGroups["sidebar-scope"]
        XCTAssertTrue(scope.waitToExist(timeout: 30), "The sidebar carries its Tables and Favorites control")
        let tables = scope.radioButtons["Tables"]
        let favorites = scope.radioButtons["Favorites"]
        XCTAssertTrue(tables.waitToExist(timeout: 10))
        XCTAssertTrue(favorites.exists)

        XCTAssertTrue(waitUntilHittable(favorites, timeout: 10))
        favorites.click()
        let noFavorites = window.staticTexts["No Favorites"]
        XCTAssertTrue(noFavorites.waitToExist(timeout: 15), "The Favorites segment must show the Favorites list")

        XCTAssertTrue(waitUntilHittable(tables, timeout: 10))
        tables.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { !noFavorites.exists },
            "The Tables segment must take the sidebar back from the Favorites list"
        )
        XCTAssertTrue(
            objectBrowser(in: window).descendants(matching: .staticText).firstMatch.waitToExist(timeout: 15),
            "The object browser must list the sample's tables again"
        )
    }

    /// A definition that is not on the server yet has nothing to reload, so Refresh leaves the
    /// titlebar on a Create Table tab, and the commit control is labelled with that tab's verb.
    /// `NSToolbarItem.isHidden` is macOS 15; below it the item stays and dims, which is a different
    /// assertion and one the unit suites make.
    func testRefreshLeavesTheToolbarOnACreateTableTab() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("NSToolbarItem.isHidden is macOS 15 and later; below it Refresh stays and dims")
        }
        try skipUnlessTheScreenFitsThePinnedWindow()
        let app = try launchWithSampleDatabase(environment: pinnedEnvironment, arguments: englishArguments)
        let window = try connectionWindow(of: app)
        let toolbar = try shownToolbar(of: window, in: app)

        let refresh = toolbar.buttons["Refresh"]
        XCTAssertTrue(
            refresh.waitToExist(timeout: 30),
            "A table tab shows Refresh, or its absence below would prove nothing"
        )
        XCTAssertTrue(toolbar.buttons["Save Changes"].exists)

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 20))
        menuBar.menuBarItems["Database"].click()
        menuBar.menuItems["New Table…"].click()
        XCTAssertTrue(
            window.buttons["create-table-commit"].firstMatch.waitToExist(timeout: 30),
            "Database > New Table… must open a Create Table tab"
        )

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !refresh.exists },
            "An unsaved definition has nothing to reload, so Refresh leaves the titlebar"
        )
        XCTAssertTrue(
            toolbar.buttons["Create Table"].waitToExist(timeout: 10),
            "The commit control names the verb of the tab it commits"
        )
    }

    // MARK: - Helpers

    /// The window the toolbar test measures is pinned, because a restored frame narrow enough to
    /// overflow the toolbar would move items into the overflow menu for reasons that have nothing to
    /// do with the context, and an item in the overflow menu is not in the toolbar to find.
    private let pinnedWindowSize = CGSize(width: 1_512, height: 861)

    private var pinnedEnvironment: [String: String] {
        ["TABLEPRO_SCREENSHOT_FRAME": "\(Int(pinnedWindowSize.width))x\(Int(pinnedWindowSize.height))"]
    }

    /// An `NSToolbarItem` publishes no accessibility identifier. Measured on macOS 27, each item is
    /// an `AXButton`, or an `AXMenuButton` for a pull-down, labelled with the item's label and with
    /// an empty identifier, and nothing gives one without a custom view, which the toolbar does not
    /// use. The labels are localized, so the app runs in English. `AppleLanguages` only takes effect
    /// as a launch argument.
    private let englishArguments = ["-AppleLanguages", "(en)"]

    /// The runner's screen is 1024pt wide, and a window pinned wider than its screen overflows the
    /// toolbar's items into the overflow menu, where none of them is in the toolbar to find. That is
    /// unmeasurable rather than wrong, so it skips.
    private func skipUnlessTheScreenFitsThePinnedWindow() throws {
        let width = NSScreen.main?.frame.width ?? 0
        try XCTSkipUnless(
            width >= pinnedWindowSize.width,
            """
            Needs a screen at least \(Int(pinnedWindowSize.width))pt wide to hold the pinned window; \
            this one is \(Int(width))pt, and anything narrower overflows toolbar items into its menu.
            """
        )
    }

    private func connectionWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        return window
    }

    /// Normalised rather than asserted, the way `SwitcherWithoutToolbarAnchorUITests` does it.
    /// AppKit persists whether the toolbar is shown through its own defaults rather than the sandbox
    /// `UITestCase` hands the app, so a run inherits whatever the last one left.
    private func shownToolbar(of window: XCUIElement, in app: XCUIApplication) throws -> XCUIElement {
        let toolbar = window.toolbars.firstMatch
        if !toolbar.waitToExist(timeout: 10) {
            app.typeKey("t", modifierFlags: [.command, .option])
        }
        XCTAssertTrue(toolbar.waitToExist(timeout: 10), "Command Option T must show the toolbar")
        return toolbar
    }

    /// Creates a connection that cannot answer and opens it. The form is driven the way a person
    /// drives it, because a hand-written `connections.json` would pin the storage format rather
    /// than the behaviour under test.
    private func openProbeConnection(in app: XCUIApplication) throws {
        let newConnection = app.menuBars.menuItems["New Connection…"]
        XCTAssertTrue(newConnection.waitToExist(timeout: 10))
        newConnection.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10))
        let search = sheet.searchFields.firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(search, timeout: 10))
        search.click()
        search.typeText("PostgreSQL")

        let driverRow = sheet.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "PostgreSQL"))
            .firstMatch
        XCTAssertTrue(driverRow.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(driverRow, timeout: 10))
        driverRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        let form = app.windows["connection-form"]
        XCTAssertTrue(form.waitToExist(timeout: 10))

        let name = form.textFields["connection-form-name"]
        XCTAssertTrue(name.waitToExist(timeout: 10))
        name.click()
        app.typeText("Probe")

        let host = form.textFields["connection-form-host"]
        XCTAssertTrue(host.waitToExist(timeout: 10))
        host.click()
        host.typeKey("a", modifierFlags: .command)
        app.typeText("192.0.2.1")

        let save = form.buttons["Save"]
        XCTAssertTrue(save.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(save, timeout: 10))
        save.click()
        XCTAssertTrue(waitForPredicate(timeout: 15) { !form.exists }, "Save should close the form")

        /// The row combines its children into one static text whose value carries the name and the
        /// host, `Probe, 192.0.2.1`, and no label; the runner's element tree shows it that way.
        let row = app.windows["welcome"].staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Probe"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 15), "The saved connection must be listed on the welcome window")
        XCTAssertTrue(waitUntilHittable(row, timeout: 10))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
    }

    private func disconnect(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Database"].click()
        menuBar.menuItems["Disconnect"].click()
    }

    /// Reconnect replaces Disconnect once the session is gone, so its enablement is the cheapest
    /// proof the disconnect landed. The menu is closed again on every pass, because an item only
    /// answers `isEnabled` while its menu is up.
    private func waitForDisconnect(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let menuBar = app.menuBars.firstMatch
            menuBar.menuBarItems["Database"].click()
            let disconnectItem = menuBar.menuItems["Disconnect"]
            guard disconnectItem.waitToExist(timeout: 5) else { continue }
            let isStillConnected = disconnectItem.isEnabled
            app.typeKey(.escape, modifierFlags: [])
            if !isStillConnected { return true }
        }
        return false
    }
}
