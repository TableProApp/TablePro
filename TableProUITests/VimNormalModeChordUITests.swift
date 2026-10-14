import XCTest

final class VimNormalModeChordUITests: UITestCase {
    func testVimModesKeepTheirKeys() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        enableVimMode(in: app)

        app.typeShortcut(.newTab)
        let editor = editorTextView(in: launch.window)
        XCTAssertTrue(editor.waitToExist(timeout: 10), "Cmd+T must open a query tab")
        XCTAssertTrue(waitForEditorText(editor) { $0.isEmpty }, "A new tab starts with an empty editor")

        app.typeText("iSELECT 1")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("h", modifierFlags: .option)
        app.typeKey(" ", modifierFlags: .option)
        app.typeKey("d", modifierFlags: .control)
        app.typeText("A AS a")
        expectText("SELECT 1 AS a", in: editor, "Option+H, Option+Space and Ctrl+D must not edit the query in Normal mode")

        // #2914: the editor's Escape and Vim's Escape were two monitors on one key with no defined order.
        // Each round appends a character and deletes it, which nets to nothing only while every Escape lands.
        app.typeKey(.escape, modifierFlags: [])
        for _ in 1 ... 5 {
            app.typeText("AX")
            app.typeKey(.escape, modifierFlags: [])
            app.typeText("x")
        }
        expectText("SELECT 1 AS a", in: editor, "Every Escape must leave Insert mode")

        app.typeText("A + 23")
        app.typeKey(.leftArrow, modifierFlags: .shift)
        app.typeKey(.leftArrow, modifierFlags: .shift)
        app.typeKey("h", modifierFlags: .control)
        expectText("SELECT 1 AS a + ", in: editor, "Ctrl+H in Insert mode must delete the selection, as Delete does")
    }

    private func enableVimMode(in app: XCUIApplication) {
        app.typeShortcut(.settings)
        let settings = window("settings", in: app)
        XCTAssertTrue(settings.waitToExist(timeout: 10), "Cmd+, must open Settings")
        let editorPane = settings.toolbars.buttons["Editor"]
        XCTAssertTrue(editorPane.waitToExist(timeout: 10))
        editorPane.click()

        let toggle = settings.descendants(matching: .any).matching(identifier: "vim-mode-toggle").firstMatch
        XCTAssertTrue(scrollUntilHittable(toggle, in: settings, timeout: 30), "The Editor pane must offer Vim mode")
        XCTAssertFalse(isOn(toggle), "A new sandbox starts with Vim mode off")
        toggle.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { self.isOn(toggle) }, "Vim mode must be on after the click")

        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 10), "Settings must close")
    }

    // Control characters are spelled out, so a stray Option+Space shows as <U+00A0> rather than a space.
    private func expectText(_ expected: String, in editor: XCUIElement, _ message: String) {
        XCTAssertTrue(waitForEditorText(editor) { $0 == expected }, "\(message); editor holds '\(visible(editorText(editor)))'")
    }

    private func visible(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            scalar.isASCII && scalar.value >= 0x20 ? String(scalar) : String(format: "<U+%04X>", scalar.value)
        }.joined()
    }
}
