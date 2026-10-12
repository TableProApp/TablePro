import XCTest

/// A CSV whose headers do not all match the table's columns is mapped by hand once, imported, and
/// the next import into the same table opens on that mapping.
///
/// Every query is rooted at a window or its sheet rather than at the application, because the
/// sample database's grid publishes thousands of elements and an application-wide search walks
/// all of them.
final class RowImportMappingMemoryUITests: UITestCase {
    private let fileName = "genres.csv"
    private let genres = Data("GenreId,Title\n9001,Imported genre\n".utf8)

    func testTheMappingPickedForATableComesBackOnTheNextImport() throws {
        let app = try launchWithSampleDatabase(andDataFile: fileName, contents: genres)
        let windows = rowImportWindows(in: app, dataFileTitle: fileName)

        let first = openSheetIntoGenre(windows, in: app)
        let title = element(first.popUpButtons, labelEndingWith: "Column for Title")
        XCTAssertTrue(title.waitToExist(timeout: 20), "The sheet must list the Title field")
        XCTAssertEqual(title.value as? String, "Skip", "Title matches no Genre column by name")
        element(first.checkBoxes, labelEndingWith: "Import Title").click()
        choose("Name", from: title)
        first.buttons["Import"].firstMatch.click()

        let done = windows.connection.sheets.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitToExist(timeout: 30), "The import must finish and report success")
        done.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !windows.connection.sheets.firstMatch.exists },
            "The import sheet must close after the import"
        )

        let second = openSheetIntoGenre(windows, in: app)
        let restored = element(second.popUpButtons, labelEndingWith: "Column for Title")
        XCTAssertTrue(restored.waitToExist(timeout: 20), "The sheet must list the Title field again")
        XCTAssertEqual(restored.value as? String, "Name", "Title must come back mapped to Name")
        let caption = second.staticTexts
            .matching(NSPredicate(format: "value == %@", "Restored the mapping saved for Genre."))
            .firstMatch
        XCTAssertTrue(caption.waitToExist(timeout: 5), "The sheet must say the mapping was restored")
        second.buttons["Cancel"].firstMatch.click()
    }

    private func openSheetIntoGenre(
        _ windows: (dataFile: XCUIElement, connection: XCUIElement),
        in app: XCUIApplication
    ) -> XCUIElement {
        let sheet = openRowImportSheet(
            from: windows.dataFile,
            titled: fileName,
            into: windows.connection,
            in: app
        )
        let destination = element(sheet.popUpButtons, labelEndingWith: "Import into")
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
