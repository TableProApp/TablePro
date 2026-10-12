import XCTest

/// Import into Table hands the rows over through a snapshot the data file window writes under a
/// generated name. The sheet and the table name it proposes have to come from the file the user
/// opened, not from that snapshot.
///
/// Every query is rooted at a window or its sheet, because the sample database's grid publishes
/// thousands of elements.
final class RowImportSourceNameUITests: UITestCase {
    private let fileName = "genres.csv"
    private let genres = Data("GenreId,Title\n9001,Imported genre\n".utf8)

    func testTheSheetNamesTheDataFileAndProposesATableAfterIt() throws {
        let app = try launchWithSampleDatabase(andDataFile: fileName, contents: genres)
        let windows = rowImportWindows(in: app, dataFileTitle: fileName)
        let sheet = openRowImportSheet(
            from: windows.dataFile,
            titled: fileName,
            into: windows.connection,
            in: app
        )

        let title = sheet.staticTexts.matching(NSPredicate(format: "value == %@", fileName)).firstMatch
        XCTAssertTrue(title.waitToExist(timeout: 10), "The sheet must be titled after \(fileName)")

        let newTable = sheet.radioButtons["New table"].firstMatch
        XCTAssertTrue(waitUntilHittable(newTable, timeout: 10), "The sheet must offer a new table")
        newTable.click()

        let name = sheet.textFields.matching(NSPredicate(format: "placeholderValue == %@", "table_name")).firstMatch
        XCTAssertTrue(name.waitToExist(timeout: 10), "A new table must ask for its name")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (name.value as? String) == "genres" },
            "The proposed table must be named after \(fileName), got \(name.value ?? "nothing")"
        )

        sheet.buttons["Cancel"].firstMatch.click()
    }
}
