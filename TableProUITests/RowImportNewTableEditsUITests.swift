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
    private let fileName = "genres.csv"
    private let genres = Data("GenreId,Title\n 9001 ,Imported genre\n".utf8)

    func testAColumnEditSurvivesAParsingOptionChange() throws {
        let app = try launchWithSampleDatabase(andDataFile: fileName, contents: genres)
        let windows = rowImportWindows(in: app, dataFileTitle: fileName)
        let sheet = openRowImportSheet(
            from: windows.dataFile,
            titled: fileName,
            into: windows.connection,
            in: app
        )
        let newTable = sheet.radioButtons["New table"].firstMatch
        XCTAssertTrue(waitUntilHittable(newTable, timeout: 10), "The sheet must offer a new table")
        newTable.click()

        let titleKey = element(sheet.checkBoxes, labelEndingWith: "Title is a primary key")
        XCTAssertTrue(waitUntilHittable(titleKey, timeout: 20), "The new table must list the Title column")
        titleKey.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (titleKey.value as? Int) == 1 },
            "Title must become the primary key"
        )

        let idType = element(sheet.popUpButtons, labelEndingWith: "Type of GenreId")
        XCTAssertTrue(idType.waitToExist(timeout: 10), "The new table must list the GenreId column")
        XCTAssertEqual(typeName(of: idType), "TEXT", "Untrimmed, ' 9001 ' reads as text")

        let trim = element(sheet.checkBoxes, labelEndingWith: "Trim leading and trailing spaces")
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
}
