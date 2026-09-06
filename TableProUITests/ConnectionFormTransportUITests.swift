import XCTest

/// The transport picker is the whole point of the Network tab: choosing one has to put that
/// transport's fields on screen and take the previous one's away. The view models prove the
/// booleans, and nothing below them proves the swap reaches the form.
final class ConnectionFormTransportUITests: UITestCase {
    private let transportPicker = "connection-form-transport"
    private let sshHost = "connection-form-ssh-host"
    private let socksHost = "connection-form-socks-host"

    func testChoosingATransportReplacesThePreviousOnesFields() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "PostgreSQL", in: app)
        selectTab("network", in: form)

        let picker = form.popUpButtons[transportPicker]
        XCTAssertTrue(picker.waitToExist(timeout: 10), "The Network tab should offer a Connect via picker")

        XCTAssertFalse(form.textFields[sshHost].exists, "Direct shows no transport fields")
        XCTAssertFalse(form.textFields[socksHost].exists)

        select(option: "SSH Tunnel", in: picker)
        XCTAssertTrue(
            form.textFields[sshHost].waitToExist(timeout: 5),
            "Choosing SSH Tunnel should show the SSH server fields"
        )
        XCTAssertFalse(form.textFields[socksHost].exists)

        select(option: "SOCKS Proxy", in: picker)
        XCTAssertTrue(
            form.textFields[socksHost].waitToExist(timeout: 5),
            "Choosing SOCKS Proxy should show the proxy fields"
        )
        XCTAssertFalse(
            form.textFields[sshHost].exists,
            "A connection uses one transport, so the SSH fields go when SOCKS is chosen"
        )

        select(option: "Direct", in: picker)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !form.textFields[socksHost].exists },
            "Direct should leave no transport fields on screen"
        )
        XCTAssertFalse(form.textFields[sshHost].exists)
    }

    func testTheActionBarNamesWhatIsBlockingSave() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "PostgreSQL", in: app)

        let validation = form.descendants(matching: .any).matching(identifier: "connection-form-validation")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { validation.count > 0 },
            "An unnamed connection should say so beside the dimmed Save button"
        )

        let name = form.textFields["connection-form-name"]
        XCTAssertTrue(name.waitToExist(timeout: 5))
        name.click()
        app.typeText("Probe")

        XCTAssertTrue(
            waitForPredicate(timeout: 5) { validation.count == 0 },
            "Naming the connection should clear the message"
        )
    }

    // MARK: - Helpers

    /// The sections are a `NavigationSplitView` sidebar, so each row publishes as an outline row
    /// rather than the radio button an `NSSegmentedControl` gave. Reached by the row's own
    /// identifier, because a sidebar row's label is nested and does not answer a subscript by title.
    ///
    /// Not finding the row fails the test rather than skipping it: a section list the accessibility
    /// tree cannot see is a section list VoiceOver cannot drive.
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

    private func openConnectionForm(for type: String, in app: XCUIApplication) throws -> XCUIElement {
        let newConnection = app.menuBars.menuItems["New Connection…"]
        XCTAssertTrue(newConnection.waitToExist(timeout: 10))
        newConnection.click()

        /// Scoped to the sheet, not the app: the welcome window behind it owns a `sidebar-filter`
        /// search field that `app.searchFields.firstMatch` reaches first, so the driver name went
        /// into the connection filter, the chooser list stayed unfiltered, and the wanted row was
        /// never realised.
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

    private func select(option: String, in picker: XCUIElement) {
        XCTAssertTrue(waitUntilHittable(picker, timeout: 10))
        picker.click()
        let item = picker.menuItems[option]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The transport picker should offer \(option)")
        item.click()
    }
}
