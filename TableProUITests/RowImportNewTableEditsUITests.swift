import XCTest

/// A new table's column edits outlive a parsing option change, while what the user left alone follows
/// the new read.
///
/// `GenreId` holds ` 9001 `, which reads as text until **Trim leading and trailing spaces** is on and
/// as a number after it, so the type menu of the untouched column is what shows the file was read
/// again. The key set on `Title` is the edit the read used to throw away. The file reaches the sheet
/// through the data file window's Import into Table, the one route that needs no open panel, and every
/// query is rooted at a window or its sheet because the sample database's grid publishes thousands of
/// elements.
final class RowImportNewTableEditsUITests: UITestCase {
    private let genres = Data("GenreId,Title\n 9001 ,Imported genre\n".utf8)

    func testAColumnEditSurvivesAParsingOptionChange() throws {
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

        let sheet = try openImportSheet(from: dataWindow, into: connectionWindow, in: app)
        let newTable = sheet.radioButtons["New table"].firstMatch
        XCTAssertTrue(waitUntilHittable(newTable, timeout: 10), "The sheet must offer a new table")
        newTable.click()

        let titleKey = sheet.checkBoxes["Title is a primary key"].firstMatch
        XCTAssertTrue(waitUntilHittable(titleKey, timeout: 20), "The new table must list the Title column")
        titleKey.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (titleKey.value as? Int) == 1 },
            "Title must become the primary key"
        )

        let idType = sheet.popUpButtons["Type of GenreId"].firstMatch
        XCTAssertTrue(idType.waitToExist(timeout: 10), "The new table must list the GenreId column")
        XCTAssertEqual(typeName(of: idType), "TEXT", "Untrimmed, ' 9001 ' reads as text")

        let trim = sheet.checkBoxes["Trim leading and trailing spaces"].firstMatch
        XCTAssertTrue(waitUntilHittable(trim, timeout: 10), "The CSV options must be in the sheet")
        trim.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { typeName(of: idType) == "INTEGER" },
            "Trimming must read the file again and propose a number for the untouched GenreId column"
        )
        XCTAssertEqual(titleKey.value as? Int, 1, "The key set on Title must survive the new read")

        sheet.buttons["Cancel"].firstMatch.click()
    }

    private func typeName(of popUp: XCUIElement) -> String? {
        (popUp.value as? String)?.uppercased()
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
        return sheet
    }
}
