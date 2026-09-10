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
        dismissOnboarding(in: app)

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
