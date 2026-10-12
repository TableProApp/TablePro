//
//  TrailingPaneSurfaceUITests.swift
//  TableProUITests
//
//  The trailing pane has one header on every surface: a picker between the inspector and the
//  assistant, or the surface's name where there is nothing to choose, and a menu of that surface's
//  commands. The View menu's two commands take their titles from the surface the pane is drawing, so
//  in Agent mode the pane toggle names the result column and Show Assistant is dimmed.
//

import XCTest

final class TrailingPaneSurfaceUITests: UITestCase {
    /// The titles are matched by their English text, so the app runs in a known language.
    private let englishArguments = ["-AppleLanguages", "(en)"]

    /// Agent mode reveals its result column on the way in, so the toggle starts on Hide Result.
    func testAgentModeRetitlesThePaneToggleAndDimsShowAssistant() throws {
        let app = try launchWithSampleDatabase(arguments: englishArguments)
        _ = try mainWindow(of: app)
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))

        menuBar.menuBarItems["View"].click()
        menuBar.menuItems["Mode"].click()
        let agent = menuBar.menuItems["Agent"]
        XCTAssertTrue(agent.waitToExist(timeout: 10), "View > Mode must offer Agent")
        agent.click()

        menuBar.menuBarItems["View"].click()
        let hideResult = menuBar.menuItems["Hide Result"]
        XCTAssertTrue(
            hideResult.waitToExist(timeout: 15),
            "In Agent mode the pane toggle names the result column it closes, not an inspector nobody sees"
        )
        XCTAssertFalse(
            menuBar.menuItems["Hide Inspector"].exists,
            "The inspector is not on screen in Agent mode, so nothing may offer to hide it"
        )
        let showAssistant = menuBar.menuItems["Show Assistant"]
        XCTAssertTrue(showAssistant.exists)
        XCTAssertFalse(
            showAssistant.isEnabled,
            "The conversation is the content column in Agent mode, so there is no assistant to show"
        )

        hideResult.click()
        menuBar.menuBarItems["View"].click()
        XCTAssertTrue(
            menuBar.menuItems["Show Result"].waitToExist(timeout: 10),
            "Closing the result column must leave a command that brings it back"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The picker writes the connection's surface and the window swaps the pane on the next turn of
    /// the run loop, after the picker's own action has returned. The inspector's field search leaving
    /// the window is what shows the swap happened.
    func testTheHeaderPickerMovesThePaneToTheAssistant() throws {
        let app = try launchWithSampleDatabase(arguments: englishArguments)
        let window = try mainWindow(of: app)
        selectFirstRow(in: window)
        showInspector(in: app)
        XCTAssertTrue(
            window.searchFields["inspector-field-search"].waitToExist(timeout: 20),
            "The inspector must be showing the row's fields before the pane can move off it"
        )

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.surfaceSegment("Assistant", in: window).exists },
            "The inspector's header offers the assistant while AI is on, named rather than by its glyph"
        )
        let assistant = surfaceSegment("Assistant", in: window)
        XCTAssertTrue(waitUntilHittable(assistant, timeout: 10))
        assistant.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 15) { !window.searchFields["inspector-field-search"].exists },
            "Picking the assistant must take the inspector off the pane"
        )
        let menu = window.descendants(matching: .any)["trailing-pane-menu"].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { menu.exists && menu.label == "Assistant Options" },
            "The assistant draws the same header as the inspector, carrying its own commands"
        )

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["View"].click()
        XCTAssertTrue(
            menuBar.menuItems["Hide Assistant"].waitToExist(timeout: 10),
            "The View menu reads the surface the pane is drawing"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Fields and JSON are a choice in the inspector's menu now, not a second segmented control
    /// beside the surface picker.
    func testTheInspectorMenuSwitchesTheRowToJSON() throws {
        let app = try launchWithSampleDatabase(arguments: englishArguments)
        let window = try mainWindow(of: app)
        selectFirstRow(in: window)
        showInspector(in: app)

        let menu = window.descendants(matching: .any)["trailing-pane-menu"].firstMatch
        XCTAssertTrue(menu.waitToExist(timeout: 20), "Every surface's header carries its commands menu")
        XCTAssertEqual(
            menu.label,
            "Inspector Options",
            "The ellipsis draws no text, so its label is the only name VoiceOver has for it"
        )
        XCTAssertTrue(waitUntilHittable(menu, timeout: 10))
        menu.click()

        let json = window.menuItems["JSON"].firstMatch
        XCTAssertTrue(json.waitToExist(timeout: 10), "The inspector's menu offers the JSON rendering")
        json.click()

        XCTAssertTrue(
            window.searchFields["json-row-filter"].waitToExist(timeout: 20),
            "Choosing JSON must show the row as JSON"
        )
    }

    // MARK: - Helpers

    private func mainWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        return window
    }

    /// A segmented control publishes its segments as radio buttons, and the CI runner has been seen
    /// publishing the same controls as plain buttons, so both are asked, inside the picker first.
    private func surfaceSegment(_ title: String, in window: XCUIElement) -> XCUIElement {
        let radio = window.radioGroups["trailing-pane-surface"].radioButtons[title].firstMatch
        return radio.exists ? radio : window.buttons.matching(identifier: title).firstMatch
    }

    /// A point offset from the grid rather than a row: the grid publishes its columns as siblings of
    /// its rows, so XCUITest reads every row as obscured and refuses to click one. `dy` clears the
    /// 42pt header, and the rows have to be in first or the click lands on an empty grid.
    private func selectFirstRow(in window: XCUIElement) {
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The sample database produced no data grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "The sample table must load rows before one is selected")
        gridPoint(in: grid, of: window, dy: 70).click()
    }

    /// The pane remembers whether it was open and on which surface, so the starting state is
    /// whatever the previous launch left. Show Inspector is offered in every state but one, the
    /// inspector already on screen.
    private func showInspector(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()

        let show = menuBar.menuItems["Show Inspector"]
        if show.waitToExist(timeout: 5) {
            show.click()
            return
        }
        app.typeKey(.escape, modifierFlags: [])
    }
}
