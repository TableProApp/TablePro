import XCTest

final class InvisibleCharacterUITests: UITestCase {
    func testControlChordDoesNotTypeABackspaceCharacter() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText("SELECT 1")
        app.typeKey("h", modifierFlags: [.control, .option])
        app.typeText(" AS a")

        XCTAssertTrue(
            waitForValue("SELECT 1 AS a", in: editor),
            "Control+Option+H must not leave U+0008 in the query; editor holds "
                + "'\(debugValue(of: editor))'"
        )
    }

    func testRemoveInvisibleCharactersCleansTheQuery() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText("SELECT")
        app.typeKey(" ", modifierFlags: .option)
        app.typeText("1")
        XCTAssertTrue(
            waitForValue("SELECT\u{A0}1", in: editor),
            "Option+Space types a non-breaking space; editor holds '\(debugValue(of: editor))'"
        )

        let item = app.menuBars.menuItems["Remove Invisible Characters"]
        XCTAssertTrue(item.waitToExist(timeout: 10), "Query > Remove Invisible Characters must exist")
        item.click()

        XCTAssertTrue(
            waitForValue("SELECT 1", in: editor),
            "The non-breaking space must become a space; editor holds '\(debugValue(of: editor))'"
        )
    }

    private func openQueryTab(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor), "A new tab starts with an empty editor")
        return editor
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
