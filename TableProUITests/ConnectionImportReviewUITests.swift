import XCTest

final class ConnectionImportReviewUITests: UITestCase {
    private static let fixture = """
    {
      "formatVersion": 2,
      "exportedAt": "2026-10-10T09:00:00Z",
      "appVersion": "0.70.0",
      "connections": [
        {
          "ref": "c1",
          "name": "Review Orders",
          "host": "127.0.0.1",
          "port": 3306,
          "database": "orders",
          "username": "app",
          "type": "MySQL"
        }
      ],
      "savedQueries": [
        { "ref": "q1", "name": "Daily orders", "sql": "SELECT 1", "connectionRef": "c1" },
        { "ref": "q2", "name": "Open carts", "sql": "SELECT 2", "connectionRef": "c1" }
      ]
    }
    """

    func testSavedQueriesFollowTheirConnection() throws {
        let (_, sheet) = try openReview()

        let header = sheet.checkBoxes["import-review-queries-toggle"]
        XCTAssertTrue(header.waitToExist(timeout: 10), "The review must list the file's saved queries")
        XCTAssertTrue(isOn(header), "Both saved queries start checked")

        let second = sheet.checkBoxes["import-query-q2"]
        XCTAssertTrue(waitUntilHittable(second, timeout: 5))
        second.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.isMixed(header) },
            "One of two queries checked must leave the Saved Queries header mixed"
        )

        let connection = sheet.checkBoxes["import-connection-c1"]
        XCTAssertTrue(waitUntilHittable(connection, timeout: 5))
        connection.click()
        let first = sheet.checkBoxes["import-query-q1"]
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !first.isEnabled && !second.isEnabled },
            "Unchecking the connection must disable the saved queries that belong to it"
        )
        XCTAssertTrue(
            sheet.staticTexts.matching(Self.text("Its connection is not imported.")).firstMatch.exists,
            "A disabled query must say why"
        )
    }

    func testImportReportsConnectionsAndSavedQueries() throws {
        let (app, sheet) = try openReview()

        let importButton = sheet.buttons["import-review-import"]
        XCTAssertTrue(waitUntilHittable(importButton, timeout: 10))
        importButton.click()

        let message = app.staticTexts
            .matching(Self.text("1 connection was imported. 2 saved queries were added."))
            .firstMatch
        XCTAssertTrue(message.waitToExist(timeout: 15), "The result alert must count the connection and both queries")
    }

    private func openReview() throws -> (XCUIApplication, XCUIElement) {
        let app = try launchWithConnectionShare(
            named: "Review Orders.tablepro",
            contents: Data(Self.fixture.utf8)
        )
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 15), "Opening a connection file must show the welcome window")
        let sheet = welcome.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 15), "Opening a connection file must show the import review")
        return (app, sheet)
    }

    private func isMixed(_ checkbox: XCUIElement) -> Bool {
        if let number = checkbox.value as? Int { return number == 2 }
        let text = (checkbox.value as? String) ?? ""
        return text == "2" || text.lowercased() == "mixed"
    }

    private static func text(_ string: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR value == %@", string, string)
    }
}
