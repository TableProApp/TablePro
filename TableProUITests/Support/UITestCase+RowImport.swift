import XCTest

/// Reaches the row import sheet through the data file window's Import into Table, the one route to
/// the sheet that needs no open panel.
///
/// On a 1024pt runner screen the data file window and the connection window open on the same frame,
/// so a click aimed at the data file's grid lands on whichever window is in front, which after an
/// import is the connection window. The data file window is brought forward through the Window menu
/// instead, by its title.
extension UITestCase {
    internal func launchWithSampleDatabase(andDataFile name: String, contents: Data) throws -> XCUIApplication {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let fileURL = root.appendingPathComponent(name)
        try contents.write(to: fileURL)
        return try launchApp(environment: [
            "TABLEPRO_UI_TEST_OPEN_SAMPLE": "1",
            "TABLEPRO_UI_TEST_OPEN_FILE": fileURL.path
        ])
    }

    internal func rowImportWindows(
        in app: XCUIApplication,
        dataFileTitle: String
    ) -> (dataFile: XCUIElement, connection: XCUIElement) {
        let dataWindow = app.windows.matching(identifier: "main-data-file").firstMatch
        XCTAssertTrue(dataWindow.waitToExist(timeout: 30), "\(dataFileTitle) produced no data file window")
        let connectionWindow = app.windows
            .matching(NSPredicate(format: "identifier != %@", "main-data-file"))
            .firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                objectBrowser(in: connectionWindow).descendants(matching: .staticText).firstMatch.exists
            },
            "The sample database never finished opening"
        )
        return (dataWindow, connectionWindow)
    }

    internal func openRowImportSheet(
        from dataWindow: XCUIElement,
        titled dataFileTitle: String,
        into connectionWindow: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement {
        let grid = dataWindow.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The data file window has no grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "The data file must load rows")

        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Window"].click()
        let windowItem = menuBar.menuBarItems["Window"].menus.menuItems
            .matching(NSPredicate(format: "title == %@", dataFileTitle))
            .firstMatch
        XCTAssertTrue(windowItem.waitToExist(timeout: 10), "The Window menu must list \(dataFileTitle)")
        windowItem.click()

        let edit = menuBar.menuBarItems["Edit"]
        edit.click()
        let data = edit.menus.menuItems["Data"].firstMatch
        XCTAssertTrue(data.waitToExist(timeout: 5), "Edit must carry the Data submenu")
        data.hover()
        let importItem = data.menus.menuItems["Import into Table…"].firstMatch
        XCTAssertTrue(importItem.waitToExist(timeout: 5), "Data must offer Import into Table")
        importItem.click()

        let proceed = dataWindow.sheets.buttons["Continue"].firstMatch
        XCTAssertTrue(proceed.waitToExist(timeout: 15), "Import into Table must ask for a connection")
        proceed.click()

        let sheet = connectionWindow.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 30), "The import sheet must open in the connection window")
        return sheet
    }

    /// A SwiftUI control with `labelsHidden()` and its own accessibility label publishes both,
    /// joined, as `"Title, Import Title"` on the runner, so a subscript by the accessibility label
    /// alone finds nothing there.
    internal func element(
        _ query: XCUIElementQuery,
        labelEndingWith label: String
    ) -> XCUIElement {
        query.matching(NSPredicate(format: "label ENDSWITH %@", label)).firstMatch
    }
}
