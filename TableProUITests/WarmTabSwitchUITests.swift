import XCTest

// #2424: a warm switch now keeps each tab's formatted cells, so a tab has to come back with its own
// rows rather than blank or holding the other tab's.
final class WarmTabSwitchUITests: UITestCase {
    private struct LoadedTable {
        let title: String
        let ownCell: String
        let otherCell: String
        let rowCount: String
    }

    private static let album = LoadedTable(title: "album", ownCell: "North", otherCell: "Ada", rowCount: "6 rows")
    private static let artist = LoadedTable(title: "artist", ownCell: "Ada", otherCell: "North", rowCount: "5 rows")

    func testAlternatingBetweenTwoLoadedTableTabsKeepsEachTabsOwnRows() throws {
        let launch = try launchWithFixture([ConnectionSeed(tabs: [.table("album"), .table("artist")])])
        let window = launch.window

        XCTAssertTrue(waitForRows(of: Self.album, in: window), "album must load before the switching begins")
        selectEditorTab(titled: Self.artist.title, in: window)
        XCTAssertTrue(waitForRows(of: Self.artist, in: window), "artist must load before the switching begins")

        for _ in 0 ..< 3 {
            for table in [Self.album, Self.artist] {
                selectEditorTab(titled: table.title, in: window)
                XCTAssertTrue(
                    waitForRows(of: table, in: window),
                    "Returning to \(table.title) must show its own rows; the bar reads \(readout(in: window) ?? "nothing")"
                )
            }
        }
    }

    private func waitForRows(of table: LoadedTable, in window: XCUIElement) -> Bool {
        let grid = dataGrid(in: window)
        return waitForPredicate(timeout: 15) {
            gridCell(showing: table.ownCell, in: grid).exists
                && !gridCell(showing: table.otherCell, in: grid).exists
                && (readout(in: window)?.contains(table.rowCount) ?? false)
        }
    }

    private func readout(in window: XCUIElement) -> String? {
        let element = window.staticTexts["result-status-readout"].firstMatch
        guard element.exists else { return nil }
        return (element.value as? String) ?? element.label
    }
}
