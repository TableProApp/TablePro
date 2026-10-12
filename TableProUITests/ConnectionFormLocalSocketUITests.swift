import XCTest

final class ConnectionFormLocalSocketUITests: UITestCase {
    private let endpointPicker = "connection-form-endpoint"
    private let socketField = "connection-form-socket-path"
    private let hostField = "connection-form-host"
    private let portField = "connection-form-port"
    private let transportPicker = "connection-form-transport"

    func testSocketReplacesHostAndPortAndLeavesOnlyDirect() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "MySQL", in: app)
        let name = form.textFields["connection-form-name"]
        XCTAssertTrue(name.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(name, timeout: 10))
        name.click()
        app.typeText("Local")

        let picker = form.popUpButtons[endpointPicker]
        XCTAssertTrue(picker.waitToExist(timeout: 10), "MySQL should offer Connect Using")
        XCTAssertTrue(form.textFields[hostField].exists, "Host and Port is the default")
        XCTAssertFalse(form.textFields[socketField].exists)

        select(option: "Socket", in: picker)
        XCTAssertTrue(form.textFields[socketField].waitToExist(timeout: 5), "Socket should show its path field")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !form.textFields[self.hostField].exists },
            "Socket replaces Host"
        )
        XCTAssertFalse(form.textFields[portField].exists, "Socket replaces Port")

        let validation = form.descendants(matching: .any).matching(identifier: "connection-form-validation")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { validation.firstMatch.exists },
            "An empty socket path should dim Save"
        )
        let reason = validation.firstMatch.label + " " + String(describing: validation.firstMatch.value ?? "")
        XCTAssertTrue(reason.contains("Socket"), "Save should wait for the socket path, not: \(reason)")

        selectConnectionFormTab("network", in: form)
        let transport = form.popUpButtons[transportPicker]
        XCTAssertTrue(transport.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(transport, timeout: 10))
        transport.click()
        XCTAssertTrue(transport.menuItems["Direct"].waitToExist(timeout: 5))
        XCTAssertEqual(transport.menuItems.count, 1, "A socket connection offers only Direct")
        app.typeKey(.escape, modifierFlags: [])

        selectConnectionFormTab("general", in: form)
        let socket = form.textFields[socketField]
        XCTAssertTrue(socket.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(socket, timeout: 10))
        socket.click()
        app.typeText("/tmp/mysql.sock")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !validation.firstMatch.exists },
            "A valid socket path should leave nothing blocking Save"
        )

        select(option: "Host and Port", in: form.popUpButtons[endpointPicker])
        XCTAssertTrue(form.textFields[hostField].waitToExist(timeout: 5), "Host and Port should come back")
        XCTAssertFalse(form.textFields[socketField].exists)
    }

    private func select(option: String, in picker: XCUIElement) {
        XCTAssertTrue(waitUntilHittable(picker, timeout: 10))
        picker.click()
        let item = picker.menuItems[option]
        XCTAssertTrue(item.waitToExist(timeout: 5), "The picker should offer \(option)")
        item.click()
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
