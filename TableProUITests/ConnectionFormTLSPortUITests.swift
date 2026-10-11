import XCTest

/// The port lives on the General tab and the SSL mode on the Network tab, so typing a port that
/// the engine's own clients treat as TLS has to change a control on a tab the user is not looking
/// at, and say so beside the field they are typing in. ClickHouse drives it because it ships in
/// the app; Trino takes the same path but is registry-only.
final class ConnectionFormTLSPortUITests: UITestCase {
    private let portField = "connection-form-port"
    private let portNote = "connection-form-port-tls-note"
    private let sslModePicker = "connection-form-ssl-mode"

    func testTypingATLSPortTurnsOnVerifyIdentityAndTypingAnotherTurnsItOff() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "ClickHouse", in: app)
        let port = form.textFields[portField]
        XCTAssertTrue(port.waitToExist(timeout: 10), "The General tab should offer a Port field")
        XCTAssertFalse(hasElement(portNote, in: form), "The default port is not a TLS port")

        replaceText(in: port, with: "8443")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.hasElement(self.portNote, in: form) },
            "Port 8443 should say beside the field that it turned SSL on"
        )

        selectConnectionFormTab("network", in: form)
        let picker = form.popUpButtons[sslModePicker]
        XCTAssertTrue(picker.waitToExist(timeout: 10), "The Network tab should offer the SSL Mode picker")
        XCTAssertEqual(picker.value as? String, "Verify Identity")

        selectConnectionFormTab("general", in: form)
        replaceText(in: form.textFields[portField], with: "8123")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !self.hasElement(self.portNote, in: form) },
            "Leaving the TLS port should take the note away"
        )

        selectConnectionFormTab("network", in: form)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (form.popUpButtons[self.sslModePicker].value as? String) == "Disabled" },
            "The mode the port turned on should go back to the default with it"
        )
    }

    func testDisabledOnATLSPortOffersVerifyIdentityBesideThePort() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "ClickHouse", in: app)
        let port = form.textFields[portField]
        XCTAssertTrue(port.waitToExist(timeout: 10))
        replaceText(in: port, with: "8443")

        selectConnectionFormTab("network", in: form)
        let picker = form.popUpButtons[sslModePicker]
        XCTAssertTrue(picker.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(picker, timeout: 10))
        picker.click()
        let disabled = picker.menuItems["Disabled"]
        XCTAssertTrue(disabled.waitToExist(timeout: 5), "The SSL Mode picker should offer Disabled")
        disabled.click()

        selectConnectionFormTab("general", in: form)
        let useVerifyIdentity = form.buttons["connection-form-port-tls-use"]
        XCTAssertTrue(
            useVerifyIdentity.waitToExist(timeout: 5),
            "Disabled on a TLS port should offer Verify Identity beside the Port field"
        )
        XCTAssertFalse(hasElement(portNote, in: form))
        XCTAssertTrue(waitUntilHittable(useVerifyIdentity, timeout: 10))
        useVerifyIdentity.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.hasElement(self.portNote, in: form) },
            "Taking the offer should turn Verify Identity on"
        )
        selectConnectionFormTab("network", in: form)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) {
                (form.popUpButtons[self.sslModePicker].value as? String) == "Verify Identity"
            }
        )
    }

    private func hasElement(_ identifier: String, in form: XCUIElement) -> Bool {
        form.descendants(matching: .any).matching(identifier: identifier).count > 0
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(waitUntilHittable(field, timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

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
