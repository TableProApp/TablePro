import XCTest

final class ConnectionEditorIssueJumpUITests: UITestCase {
    func testTheCommitBarJumpsToAnIssueOnAnotherFacetAndSaveListsTheConnection() throws {
        let name = "Tunnel Flow"
        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        app.typeShortcut(.newConnection)
        let chooser = welcome.sheets.firstMatch
        let search = chooser.searchFields["database-type-chooser-search"]
        XCTAssertTrue(waitUntilHittable(search, timeout: 10), "New Connection must present the database chooser")
        search.click()
        search.typeText("PostgreSQL")
        let proceed = chooser.buttons["Continue"]
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { proceed.exists && proceed.isEnabled },
            "An exact type name must arm Continue"
        )
        proceed.click()

        let editor = window("connection-form", in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10), "Choosing PostgreSQL must open the connection editor")
        replaceText(in: editor.textFields["connection-form-name"], with: name)

        showFacet("sshAndProxies", in: editor)
        let transport = editor.popUpButtons["connection-form-transport"]
        XCTAssertTrue(waitUntilHittable(transport, timeout: 10), "SSH & Proxies must offer the transport picker")
        transport.click()
        let sshTunnel = transport.menuItems["SSH Tunnel"]
        XCTAssertTrue(sshTunnel.waitToExist(timeout: 5), "PostgreSQL must offer an SSH tunnel")
        sshTunnel.click()
        let sshHost = editor.textFields["connection-form-ssh-host"]
        XCTAssertTrue(sshHost.waitToExist(timeout: 10), "SSH Tunnel must show the SSH server rows")

        showFacet("general", in: editor)
        XCTAssertTrue(waitForPredicate(timeout: 10) { !sshHost.exists }, "General must replace the SSH rows")

        let save = editor.buttons["connection-form-save"]
        let issue = editor.descendants(matching: .any)["connection-form-validation"]
        XCTAssertTrue(waitUntilHittable(issue, timeout: 10), "The commit bar must show the issue that blocks Save")
        XCTAssertFalse(save.isEnabled, "An SSH tunnel with no host must block Save")
        issue.click()

        XCTAssertTrue(waitUntilHittable(sshHost, timeout: 10), "The issue must open the facet that holds it")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.holdsKeyboardFocus(sshHost) },
            "The issue must put the keyboard in the field to fix"
        )
        sshHost.typeText("bastion.example.com")

        XCTAssertTrue(waitForPredicate(timeout: 10) { save.isEnabled }, "A host must clear the issue and arm Save")
        XCTAssertFalse(issue.exists, "No issue is left to show")
        save.click()

        XCTAssertTrue(waitForPredicate(timeout: 10) { !editor.exists }, "Save must close the editor")
        let list = welcomeConnectionList(in: welcome)
        XCTAssertTrue(
            welcomeConnectionRow(named: name, in: list).waitToExist(timeout: 10),
            "The saved connection must be listed in Welcome"
        )
    }

    // The table publishes its own cell element, so the row's label carries the facet's identifier.
    private func showFacet(_ facet: String, in editor: XCUIElement) {
        let row = editor.staticTexts["connection-editor-sidebar-\(facet)"]
        XCTAssertTrue(waitUntilHittable(row, timeout: 10), "The sidebar must list \(facet)")
        row.click()
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(waitUntilHittable(field, timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }
}
