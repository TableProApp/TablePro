import XCTest

final class VimNormalModeChordUITests: UITestCase {
    private var appWithVimMode: XCUIApplication?

    override func tearDownWithError() throws {
        continueAfterFailure = true
        if let appWithVimMode {
            setVimMode(false, in: appWithVimMode)
        }
        appWithVimMode = nil
        try super.tearDownWithError()
    }

    func testNormalModeChordsNeverTypeIntoTheQuery() throws {
        let app = try launchWithSampleDatabase()
        enableVimModeUntilTearDown(in: app)
        let editor = openQueryTab(in: app)

        app.typeText("iSELECT 1")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey("h", modifierFlags: .option)
        app.typeKey(" ", modifierFlags: .option)
        app.typeKey("d", modifierFlags: .control)
        app.typeText("A AS a")

        XCTAssertTrue(
            waitForValue("SELECT 1 AS a", in: editor),
            "Option+H, Option+Space and Ctrl+D must not edit the query in Normal mode; editor holds "
                + "'\(debugValue(of: editor))'"
        )
    }

    func testInsertModeControlHDeletesTheSelection() throws {
        let app = try launchWithSampleDatabase()
        enableVimModeUntilTearDown(in: app)
        let editor = openQueryTab(in: app)

        app.typeText("i1 + 23")
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: .shift)
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: .shift)
        app.typeKey("h", modifierFlags: .control)

        XCTAssertTrue(
            waitForValue("1 + ", in: editor),
            "Ctrl+H in Insert mode must delete the selection, as Delete does; editor holds "
                + "'\(debugValue(of: editor))'"
        )
    }

    private func enableVimModeUntilTearDown(in app: XCUIApplication) {
        appWithVimMode = app
        setVimMode(true, in: app)
    }

    private func setVimMode(_ enabled: Bool, in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 20), "The app must publish its menu bar")
        menuBar.menuItems["Settings…"].click()

        let settings = app.children(matching: .window).matching(identifier: "settings").firstMatch
        XCTAssertTrue(settings.waitToExist(timeout: 10), "Settings must open")
        let editorPane = settings.toolbars.buttons["Editor"]
        XCTAssertTrue(editorPane.waitToExist(timeout: 10))
        editorPane.click()

        let vimToggle = settings.descendants(matching: .any).matching(identifier: "vim-mode-toggle").firstMatch
        XCTAssertTrue(waitUntilHittable(vimToggle, timeout: 10), "The Editor pane must offer Vim mode")
        if isOn(vimToggle) != enabled {
            vimToggle.click()
        }
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.isOn(vimToggle) == enabled },
            "Vim mode must be \(enabled ? "on" : "off") after the click"
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForPredicate(timeout: 10) { !settings.exists }, "Settings must close")
    }

    private func openQueryTab(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor), "A new tab starts with an empty editor")
        return editor
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        if let number = toggle.value as? Int { return number == 1 }
        return (toggle.value as? String) == "1"
    }

    private func waitForValue(_ expected: String, in element: XCUIElement) -> Bool {
        waitForPredicate(timeout: 10) { (element.value as? String) == expected }
    }

    private func debugValue(of element: XCUIElement) -> String {
        let value = (element.value as? String) ?? "nil"
        return value.unicodeScalars.map { scalar in
            scalar.isASCII && scalar.value >= 0x20 ? String(scalar) : String(format: "<U+%04X>", scalar.value)
        }.joined()
    }
}
