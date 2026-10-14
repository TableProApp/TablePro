import XCTest

extension UITestCase {
    /// The fixture connection and a data file window, both open at launch. A launch intent skips the
    /// session restore, so the connection opens through its `tablepro://connect/<id>` link instead.
    @discardableResult
    internal func launchWithFixture(openingDataFile name: String, contents: Data) throws -> FixtureLaunch {
        let connections = try seedSQLiteSession([ConnectionSeed()])
        let connection = try XCTUnwrap(connections.first)
        let fileURL = try writeIntoSandbox(name, contents: contents)
        let app = try launchApp(environment: [
            "TABLEPRO_UI_TEST_OPEN_FILE": fileURL.path,
            "TABLEPRO_UI_TEST_OPEN_URL": "tablepro://connect/\(connection.id.uuidString)",
        ])
        let window = mainWindow(in: app)
        XCTAssertTrue(waitForObjectBrowser(in: window), "The fixture connection never listed its tables")
        return FixtureLaunch(app: app, window: window, connections: connections)
    }

    internal func dataFileWindow(in app: XCUIApplication) -> XCUIElement {
        window("main-data-file", in: app)
    }

    // The one route to the sheet without an open panel. The data file and connection windows share a frame
    // on the 1024pt runner, so the data file window is brought forward from the Window menu, by title.
    internal func openRowImportSheet(
        from dataWindow: XCUIElement,
        titled dataFileTitle: String,
        into connectionWindow: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement {
        let grid = dataGrid(in: dataWindow)
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

    /// A SwiftUI control with `labelsHidden()` publishes both labels joined ("Title, Import Title") on the runner.
    internal func element(_ query: XCUIElementQuery, labelEndingWith label: String) -> XCUIElement {
        query.matching(NSPredicate(format: "label ENDSWITH %@", label)).firstMatch
    }
}
