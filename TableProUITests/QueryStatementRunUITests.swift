import XCTest

/// The gutter's run controls are drawn rather than hosted as a view each, so the only thing assistive technology and
/// this test can reach is the accessibility element the ribbon publishes for each one. That element is also what a
/// VoiceOver user presses, so driving it here tests the same path a real user takes.
final class QueryStatementRunUITests: UITestCase {
    private let script = "SELECT 1;\nSELECT 2;\nSELECT 3;"

    func testEachStatementPublishesItsOwnRunControl() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(script)
        XCTAssertTrue(waitForEditorText(containing: "SELECT 3", in: editor))

        let controls = runControls(in: app)
        XCTAssertTrue(
            controls.firstMatch.waitToExist(timeout: 10),
            "Every statement must publish a run control"
        )
        XCTAssertEqual(controls.count, 3, "Three statements must produce three run controls")
    }

    /// The control has to sit beside the statement it runs, so its label names the line the statement starts on.
    /// Pressing it is covered by `StatementRunControllerTests`, because XCUITest resolves a click through a positional
    /// accessibility lookup and cannot map a drawn element inside the gutter, which floats over the text view. The
    /// existing fold tests drive the Query menu for the same reason.
    func testEachRunControlIsAnchoredOnItsOwnStatementsLine() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(script)
        XCTAssertTrue(waitForEditorText(containing: "SELECT 3", in: editor))

        for line in 1...3 {
            let control = runControl(onLine: line, in: app)
            XCTAssertTrue(
                control.waitToExist(timeout: 10),
                "The statement on line \(line) must have its own run control"
            )
        }
        XCTAssertFalse(
            runControl(onLine: 4, in: app).exists,
            "A line with no statement on it must have no run control"
        )
    }

    /// A routine body is one statement, so it gets one control on its opening line rather than one per statement
    /// inside it. Splitting there is what used to send a fragment to the driver.
    func testARoutineBodyGetsASingleRunControl() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText("CREATE TRIGGER t AFTER INSERT ON a BEGIN\nUPDATE b SET x = 1;\nDELETE FROM c;\nEND;\n")
        XCTAssertTrue(waitForEditorText(containing: "DELETE FROM c", in: editor))

        let controls = runControls(in: app)
        XCTAssertTrue(controls.firstMatch.waitToExist(timeout: 10))
        XCTAssertEqual(controls.count, 1, "The whole BEGIN ... END body is one statement")
        XCTAssertTrue(
            runControl(onLine: 1, in: app).exists,
            "The one control belongs on the line the routine opens"
        )
    }

    func testAControlOnlyAppearsForAStatementThatCarriesSomething() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText("SELECT 1;\n-- just a note\n")
        XCTAssertTrue(waitForEditorText(containing: "just a note", in: editor))

        let controls = runControls(in: app)
        XCTAssertTrue(controls.firstMatch.waitToExist(timeout: 10))
        XCTAssertEqual(controls.count, 1, "A comment carries no statement, so it gets no run control")
    }

    // MARK: - Helpers

    private func runControls(in app: XCUIApplication) -> XCUIElementQuery {
        app.windows.firstMatch.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Run the statement starting on line")
        )
    }

    private func runControl(onLine line: Int, in app: XCUIApplication) -> XCUIElement {
        app.windows.firstMatch.buttons["Run the statement starting on line \(line)"]
    }

    private func openQueryTab(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        return editor
    }

    private func waitForEditorText(
        containing needle: String,
        in editor: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (editor.value as? String)?.contains(needle) == true {
                return true
            }
            usleep(200_000)
        }
        return false
    }
}
