//
//  AgentModeRoundTripUITests.swift
//  TableProUITests
//
//  Agent mode used to draw its conversation on the other arm of the conditional that drew the
//  browse content, so every trip into the mode and back rebuilt the browse tree and dropped what
//  only its views held. The query editor's undo stack is one of those: the text view owns it and the
//  tab does not, so a rebuilt editor shows the same text with nothing behind it to undo.
//

import XCTest

final class AgentModeRoundTripUITests: UITestCase {
    /// The menu titles are matched by their English text, so the app runs in a known language.
    private let englishArguments = ["-AppleLanguages", "(en)"]
    private let query = "SELECT 1"

    func testATripThroughAgentModeKeepsTheEditorsUndo() throws {
        let app = try launchWithSampleDatabase(arguments: englishArguments)
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10), "A new query tab must hold an editor")
        typeQuery(query, in: app)

        chooseMode("Agent", in: app)
        assertAgentModeIsShowing(in: app)

        chooseMode("Browse", in: app)
        XCTAssertTrue(waitUntilHittable(editor, timeout: 15), "Browsing must put the editor back")
        editor.click()
        XCTAssertEqual(editor.value as? String, query, "The tab must still hold what was typed")

        app.typeKey("z", modifierFlags: .command)

        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (editor.value as? String) != self.query },
            "Undo must still reach the typing done before the trip. A rebuilt editor has nothing to undo"
        )
    }

    // MARK: - Helpers

    private func chooseMode(_ title: String, in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()
        menuBar.menuItems["Mode"].click()
        let item = menuBar.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 10), "View > Mode must offer \(title)")
        item.click()
    }

    /// A trip that never reached Agent mode would keep the editor trivially, so the case first
    /// proves the mode is on. Its pane toggle names the result column in either state, where the
    /// browse one names the inspector or the assistant; which state depends on what earlier launches
    /// left the pane in.
    private func assertAgentModeIsShowing(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["View"].click()
        let hideResult = menuBar.menuItems["Hide Result"]
        let showResult = menuBar.menuItems["Show Result"]
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { hideResult.exists || showResult.exists },
            "Choosing Agent must put the window in Agent mode"
        )
        app.typeKey(.escape, modifierFlags: [])
    }
}
