import XCTest

// Import as Update matches the file's rows on the primary key: a matched row takes the file's value, a row whose key
// the table lacks is skipped, and the summary counts each.
final class RowImportUpdateUITests: UITestCase {
    private let fileName = "genre-changes.csv"
    private let changes = Data("id,name\n2,Bebop\n9,Polka\n".utf8)

    func testImportingAsUpdateChangesOnlyTheMatchedRows() throws {
        let launch = try launchWithFixture(openingDataFile: fileName, contents: changes)
        let app = launch.app
        let dataWindow = dataFileWindow(in: app)
        XCTAssertTrue(dataWindow.waitToExist(timeout: 30), "\(fileName) produced no data file window")
        let sheet = openRowImportSheet(from: dataWindow, titled: fileName, into: launch.window, in: app)

        choose("genre", from: element(sheet.popUpButtons, labelEndingWith: "Import into"), in: app)
        choose("Update", from: element(sheet.popUpButtons, labelEndingWith: "Import as"), in: app)
        let key = element(sheet.popUpButtons, labelEndingWith: "Match on")
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { (key.value as? String) == "Primary Key (id)" },
            "Update must match on genre's primary key, the menu shows \(key.value ?? "nothing")"
        )

        let importButton = sheet.buttons["Import"].firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { importButton.exists && importButton.isEnabled },
            "A mapped key must be ready to import"
        )
        importButton.click()

        let query = "SELECT id, name FROM genre ORDER BY id"
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                FixtureFile.rows(query, in: launch.database) == [["1", "Rock"], ["2", "Bebop"], ["3", "Metal"]]
            },
            "Only genre 2 may change and 9 must stay out, genre holds "
                + "\(FixtureFile.rows(query, in: launch.database) ?? [])"
        )
        let summary = sheet.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS %@", "Updated: 1"))
            .firstMatch
        XCTAssertTrue(summary.waitToExist(timeout: 15), "The summary must count the updated row")
        XCTAssertTrue(
            (summary.value as? String)?.contains("Skipped: 1") == true,
            "The summary must count the skipped row, it reads \(summary.value ?? "nothing")"
        )
    }

    // A pop-up's menu is built when it opens, so a list still loading is opened again.
    private func choose(_ title: String, from popUp: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(popUp.waitToExist(timeout: 15), "The sheet must offer a menu for \(title)")
        let item = app.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
        let opened = waitForPredicate(timeout: 20) {
            popUp.click()
            if item.waitToExist(timeout: 2) { return true }
            app.typeKey(.escape, modifierFlags: [])
            return false
        }
        XCTAssertTrue(opened, "The menu must offer \(title)")
        item.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (popUp.value as? String) == title },
            "The menu must show \(title), it shows \(popUp.value ?? "nothing")"
        )
    }
}
