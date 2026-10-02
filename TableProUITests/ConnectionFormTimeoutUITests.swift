import XCTest

final class ConnectionFormTimeoutUITests: UITestCase {
    func testTimeoutFieldsValidateConnectionOverrides() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let form = try openConnectionForm(for: "PostgreSQL", in: app)
        let name = form.textFields["connection-form-name"]
        XCTAssertTrue(name.waitToExist(timeout: 10))
        name.click()
        name.typeText("Timeout probe")
        selectConnectionFormTab("options", in: form)

        let connectTimeout = form.textFields["connection-form-connect-timeout"]
        let queryTimeout = form.textFields["connection-form-query-timeout"]
        XCTAssertTrue(connectTimeout.waitToExist(timeout: 10))
        XCTAssertTrue(queryTimeout.waitToExist(timeout: 10))
        XCTAssertEqual(connectTimeout.placeholderValue, "Default (30)")
        XCTAssertEqual(queryTimeout.placeholderValue, "Global (60)")

        replaceText(in: connectTimeout, with: "0")
        XCTAssertTrue(
            waitForValidation("Connect timeout must be between 1 and 600 seconds.", in: form),
            "A zero connect timeout should block saving"
        )

        replaceText(in: connectTimeout, with: "45")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !self.hasValidation(in: form) },
            "A connect timeout inside the supported range should clear validation"
        )

        replaceText(in: queryTimeout, with: "-1")
        XCTAssertTrue(
            waitForValidation("Query timeout must be between 0 and 2,147,483 seconds.", in: form),
            "A negative query timeout should block saving"
        )

        replaceText(in: queryTimeout, with: "2147484")
        XCTAssertTrue(
            waitForValidation("Query timeout must be between 0 and 2,147,483 seconds.", in: form),
            "A query timeout that overflows millisecond APIs should block saving"
        )

        replaceText(in: queryTimeout, with: "2147483")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !self.hasValidation(in: form) },
            "The largest safe query timeout should clear validation"
        )

        replaceText(in: queryTimeout, with: "0")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !self.hasValidation(in: form) },
            "Zero should be accepted as no query limit"
        )

        let save = form.buttons["Save"]
        XCTAssertTrue(save.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(save, timeout: 10))
        save.click()
        XCTAssertTrue(waitForPredicate(timeout: 15) { !form.exists }, "Save should close the form")

        let list = app.windows["welcome"].outlines["welcome-connection-list"]
        let saved = list.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Timeout probe"))
            .firstMatch
        XCTAssertTrue(saved.waitToExist(timeout: 15), "The saved connection should appear in the welcome list")
        XCTAssertTrue(waitUntilHittable(saved, timeout: 10))
        saved.rightClick()
        let edit = contextMenuItem("Edit…", in: app)
        XCTAssertTrue(waitUntilHittable(edit, timeout: 5))
        edit.click()

        let reopenedForm = app.windows["connection-form"]
        XCTAssertTrue(reopenedForm.waitToExist(timeout: 10), "Edit should reopen the saved connection")
        selectConnectionFormTab("options", in: reopenedForm)
        let reopenedConnectTimeout = reopenedForm.textFields["connection-form-connect-timeout"]
        let reopenedQueryTimeout = reopenedForm.textFields["connection-form-query-timeout"]
        XCTAssertTrue(reopenedConnectTimeout.waitToExist(timeout: 10))
        XCTAssertTrue(reopenedQueryTimeout.waitToExist(timeout: 10))
        XCTAssertEqual(reopenedConnectTimeout.value as? String, "45")
        XCTAssertEqual(reopenedQueryTimeout.value as? String, "0")
    }

    private func waitForValidation(_ message: String, in form: XCUIElement) -> Bool {
        let validation = form.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
                "connection-form-validation",
                message,
                message
            ))
            .firstMatch
        return waitForPredicate(timeout: 5) { validation.exists }
    }

    private func hasValidation(in form: XCUIElement) -> Bool {
        form.descendants(matching: .any)
            .matching(identifier: "connection-form-validation")
            .firstMatch.exists
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(waitUntilHittable(field, timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        field.typeKey(.tab, modifierFlags: [])
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
