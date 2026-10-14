import XCTest

// Import into Table reads the rows from a snapshot the data file window writes under a generated name.
// The sheet, the proposed table and the table the import creates have to follow the file the user opened.
final class RowImportSourceNameUITests: UITestCase {
    private let fileName = "genres.csv"
    private let genres = Data("GenreId,Title\n9001,Imported genre\n".utf8)

    func testImportingADataFileAddsItsRowsToANewTable() throws {
        let launch = try launchWithFixture(openingDataFile: fileName, contents: genres)
        let app = launch.app
        let dataWindow = dataFileWindow(in: app)
        XCTAssertTrue(dataWindow.waitToExist(timeout: 30), "\(fileName) produced no data file window")
        let sheet = openRowImportSheet(from: dataWindow, titled: fileName, into: launch.window, in: app)

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

        let importButton = sheet.buttons["Import"].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { importButton.exists && importButton.isEnabled },
            "A named new table must be ready to import"
        )
        importButton.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                FixtureFile.rows("SELECT * FROM genres", in: launch.database) == [["9001", "Imported genre"]]
            },
            "The import must create genres holding the file's row, the file holds "
                + "\(FixtureFile.rows("SELECT * FROM genres", in: launch.database) ?? [])"
        )
    }
}
