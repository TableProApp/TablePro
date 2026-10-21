import XCTest

final class ResultComparisonUITests: UITestCase {
    private let firstRun = "SELECT 1 AS id, 10 AS v UNION ALL SELECT 2, 20 UNION ALL SELECT 3, 30"
    private let secondRun = "SELECT 2 AS id, 99 AS v UNION ALL SELECT 3, 30 UNION ALL SELECT 4, 40"

    func testComparingARerunWithThePinnedRun() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window

        app.typeShortcut(.newTab)
        typeQuery(firstRun, in: window)
        app.typeShortcut(.runQuery)
        let grid = dataGrid(in: window)
        XCTAssertTrue(waitForClickableRows(in: grid), "The first run must fill the grid")
        XCTAssertTrue(gridCell(showing: "30", in: grid).waitToExist(timeout: 10), "The first run must show its rows")
        app.typeShortcut(.pinResult)

        typeQuery(secondRun, in: window)
        app.typeShortcut(.runQuery)
        let chooser = resultSetChooser(in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { chooser.title.contains("of 2") || chooser.title.hasSuffix("/2") },
            "The pinned run must stay beside the second one, got \(chooser.title)"
        )

        // The View menu is long enough to scroll under the pointer on the 1024x768 runner; the chooser's is short.
        XCTAssertTrue(waitUntilHittable(chooser, timeout: 10))
        chooser.click()
        let compareItem = window.menus.firstMatch.menuItems["Compare Result With…"]
        XCTAssertTrue(compareItem.waitToExist(timeout: 5), "The chooser must offer Compare Result With…")
        compareItem.click()
        let comparison = self.window("result-comparison", in: app)
        XCTAssertTrue(comparison.waitToExist(timeout: 10), "Compare Result With… must open the comparison")

        let counts = comparison.staticTexts.matching(identifier: "result-comparison.counts").firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { text(of: counts) == "2 only left, 2 only right, 0 changed, 1 same" },
            "With no table behind them the results match on whole rows, got \(text(of: counts))"
        )

        let keyMenu = comparison.descendants(matching: .any).matching(identifier: "result-comparison.key").firstMatch
        XCTAssertTrue(waitUntilHittable(keyMenu, timeout: 10))
        keyMenu.click()
        let idItem = comparison.menuItems["id"].firstMatch
        XCTAssertTrue(idItem.waitToExist(timeout: 5), "The key menu must list the shared columns")
        idItem.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { text(of: counts) == "1 only left, 1 only right, 1 changed, 1 same" },
            "Keyed on id the second row reads as changed, got \(text(of: counts))"
        )
    }

    // A SwiftUI text publishes its string as the value on some builds and as the label on others.
    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }
}
