import XCTest

/// The gutter's run controls are drawn rather than hosted as a view each, so the only thing assistive technology and
/// this test can reach is the accessibility element the ribbon publishes for each one. That element is also what a
/// VoiceOver user presses, so driving it here tests the same path a real user takes.
final class QueryStatementRunUITests: UITestCase {
    private let script = "SELECT 1;\nSELECT 2;\nSELECT 3;"

    /// One launch, one query tab, four scripts.
    ///
    /// Each of these used to launch the app and open the sample database to type a different script
    /// into an empty editor. The editor is the only thing they need, and selecting all and retyping
    /// empties it just as well as a new app does.
    ///
    /// The text is replaced rather than typed into a new tab each time, so a control left behind by
    /// a previous script cannot be counted by the next one: `runControls` matches on the window,
    /// and every count assertion here would be wrong if an earlier script's gutter survived.
    ///
    /// `continueAfterFailure` is on because the phases are independent.
    func testTheGutterPublishesOneRunControlPerStatement() throws {
        continueAfterFailure = true
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        replace(editor, in: app, with: script, settleOn: "SELECT 3")
        let controls = runControls(in: app)
        XCTAssertTrue(
            controls.firstMatch.waitToExist(timeout: 10),
            "Every statement must publish a run control"
        )
        XCTAssertEqual(controls.count, 3, "Three statements must produce three run controls")

        /// The control has to sit beside the statement it runs, so its label names the line the statement starts on.
        /// Pressing it is covered by `StatementRunControllerTests`, because XCUITest resolves a click through a
        /// positional accessibility lookup and cannot map a drawn element inside the gutter, which floats over the
        /// text view. The existing fold tests drive the Query menu for the same reason.
        for line in 1 ... 3 {
            XCTAssertTrue(
                runControl(onLine: line, in: app).waitToExist(timeout: 10),
                "The statement on line \(line) must have its own run control"
            )
        }
        XCTAssertFalse(
            runControl(onLine: 4, in: app).exists,
            "A line with no statement on it must have no run control"
        )

        /// A routine body is one statement, so it gets one control on its opening line rather than one per statement
        /// inside it. Splitting there is what used to send a fragment to the driver.
        replace(
            editor,
            in: app,
            with: "CREATE TRIGGER t AFTER INSERT ON a BEGIN\nUPDATE b SET x = 1;\nDELETE FROM c;\nEND;\n",
            settleOn: "DELETE FROM c"
        )
        XCTAssertTrue(runControls(in: app).firstMatch.waitToExist(timeout: 10))
        XCTAssertEqual(runControls(in: app).count, 1, "The whole BEGIN ... END body is one statement")
        XCTAssertTrue(
            runControl(onLine: 1, in: app).exists,
            "The one control belongs on the line the routine opens"
        )

        replace(editor, in: app, with: "SELECT 1;\n-- just a note\n", settleOn: "just a note")
        XCTAssertTrue(runControls(in: app).firstMatch.waitToExist(timeout: 10))
        XCTAssertEqual(
            runControls(in: app).count,
            1,
            "A comment carries no statement, so it gets no run control"
        )
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

    /// Select all and type over it. The editor keeps its identity, so the gutter republishes its
    /// controls for the new text instead of adding to the old ones.
    private func replace(_ editor: XCUIElement, in app: XCUIApplication, with text: String, settleOn needle: String) {
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
        XCTAssertTrue(
            waitForEditorText(containing: needle, in: editor),
            "The editor must hold the script before its run controls mean anything"
        )
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
