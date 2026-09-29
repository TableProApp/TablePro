import XCTest

/// A CSV whose headers do not all match the table's columns is mapped by hand once, imported, and
/// the next import into the same table opens on that mapping.
///
/// The file reaches the import sheet through the data file window's Import into Table, which is
/// the one route to the sheet that needs no open panel. Every query is rooted at a window or its
/// sheet rather than at the application, because the sample database's grid publishes thousands
/// of elements and an application-wide search walks all of them.
final class RowImportMappingMemoryUITests: UITestCase {
    private let genres = Data("GenreId,Title\n9001,Imported genre\n".utf8)

    func testTheMappingPickedForATableComesBackOnTheNextImport() throws {
        let app = try launchWithSampleAndFile()
        let dataWindow = app.windows.matching(identifier: "main-data-file").firstMatch
        XCTAssertTrue(dataWindow.waitToExist(timeout: 30), "The CSV produced no data file window")
        let connectionWindow = app.windows
            .matching(NSPredicate(format: "identifier != %@", "main-data-file"))
            .firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                objectBrowser(in: connectionWindow).descendants(matching: .staticText).firstMatch.exists
            },
            "The sample database never finished opening"
        )

        let first = try openImportSheet(from: dataWindow, into: connectionWindow, in: app)
        let title = first.popUpButtons["Column for Title"].firstMatch
        XCTAssertTrue(title.waitToExist(timeout: 20), "The sheet must list the Title field")
        XCTAssertEqual(title.value as? String, "Skip", "Title matches no Genre column by name")
        first.checkBoxes.matching(NSPredicate(format: "label CONTAINS %@", "Import Title")).firstMatch.click()
        choose("Name", from: title)
        first.buttons["Import"].firstMatch.click()

        let done = connectionWindow.sheets.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitToExist(timeout: 30), "The import must finish and report success")
        done.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !connectionWindow.sheets.firstMatch.exists },
            "The import sheet must close after the import"
        )

        let second = try openImportSheet(from: dataWindow, into: connectionWindow, in: app)
        let restored = second.popUpButtons["Column for Title"].firstMatch
        XCTAssertTrue(restored.waitToExist(timeout: 20), "The sheet must list the Title field again")
        XCTAssertEqual(restored.value as? String, "Name", "Title must come back mapped to Name")
        let caption = second.staticTexts
            .matching(NSPredicate(format: "value == %@", "Restored the mapping saved for Genre."))
            .firstMatch
        XCTAssertTrue(caption.waitToExist(timeout: 5), "The sheet must say the mapping was restored")
        second.buttons["Cancel"].firstMatch.click()
    }

    private func launchWithSampleAndFile() throws -> XCUIApplication {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let fileURL = root.appendingPathComponent("genres.csv")
        try genres.write(to: fileURL)
        return try launchApp(environment: [
            "TABLEPRO_UI_TEST_OPEN_SAMPLE": "1",
            "TABLEPRO_UI_TEST_OPEN_FILE": fileURL.path
        ])
    }

    private func openImportSheet(
        from dataWindow: XCUIElement,
        into connectionWindow: XCUIElement,
        in app: XCUIApplication
    ) throws -> XCUIElement {
        let grid = dataWindow.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The data file window has no grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "The data file must load rows")
        grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 80, dy: grid.tableRows.firstMatch.frame.midY - grid.frame.minY))
            .click()

        let edit = app.menuBars.menuBarItems["Edit"]
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
        let destination = sheet.popUpButtons["Import into"].firstMatch
        XCTAssertTrue(waitUntilHittable(destination, timeout: 15), "The sheet must offer the destination tables")
        choose("Genre", from: destination)
        return sheet
    }

    private func choose(_ title: String, from popUp: XCUIElement) {
        XCTAssertTrue(waitUntilHittable(popUp, timeout: 10), "\(popUp) must be clickable")
        popUp.click()
        let item = popUp.menuItems[title].firstMatch
        XCTAssertTrue(item.waitToExist(timeout: 10), "The menu must offer \(title)")
        item.click()
    }
}
