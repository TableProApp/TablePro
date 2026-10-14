import AppKit
import XCTest

final class ConnectionImportReviewUITests: UITestCase {
    private static let share = """
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

    func testImportReportsConnectionsAndSavedQueries() throws {
        let app = try launchWithConnectionShare(named: "Review Orders.tablepro", contents: Data(Self.share.utf8))
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 15), "Opening a connection file must show the welcome window")
        let sheet = welcome.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 15), "Opening a connection file must show the import review")

        let header = sheet.checkBoxes["import-review-queries-toggle"]
        XCTAssertTrue(header.waitToExist(timeout: 10), "The review must list the file's saved queries")
        XCTAssertTrue(isOn(header), "Both saved queries start checked")

        let first = sheet.checkBoxes["import-query-q1"]
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
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !first.isEnabled && !second.isEnabled },
            "Unchecking the connection must disable the saved queries that belong to it"
        )
        XCTAssertTrue(
            sheet.staticTexts.matching(Self.text("Its connection is not imported.")).firstMatch.exists,
            "A disabled query must say why"
        )

        connection.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { first.isEnabled && second.isEnabled },
            "Checking the connection again must give its saved queries back"
        )
        XCTAssertTrue(isOn(first), "The query left checked stays checked")
        XCTAssertFalse(isOn(second), "The query unchecked by hand stays unchecked")

        let importButton = sheet.buttons["import-review-import"]
        XCTAssertTrue(waitUntilHittable(importButton, timeout: 10))
        importButton.click()

        let message = app.staticTexts
            .matching(Self.text("1 connection was imported. 1 saved query was added."))
            .firstMatch
        XCTAssertTrue(
            message.waitToExist(timeout: 15),
            "The result must count the connection and only the query still checked"
        )
        app.buttons["OK"].firstMatch.click()

        let list = welcomeConnectionList(in: welcome)
        XCTAssertTrue(
            welcomeConnectionRow(named: "Review Orders", in: list).waitToExist(timeout: 10),
            "The imported connection must be listed"
        )
    }

    // XCUITest reports a mixed checkbox as NSControl.StateValue.mixed (-1), not the AXValue of 2.
    private func isMixed(_ checkbox: XCUIElement) -> Bool {
        if let number = checkbox.value as? Int { return number == NSControl.StateValue.mixed.rawValue }
        return (checkbox.value as? String) == String(NSControl.StateValue.mixed.rawValue)
    }

    private static func text(_ string: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR value == %@", string, string)
    }
}
