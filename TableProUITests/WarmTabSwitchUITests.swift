//
//  WarmTabSwitchUITests.swift
//  TableProUITests
//

import AppKit
import XCTest

/// Issue #2424. A warm switch between two loaded table tabs used to rebuild the whole grid and
/// re-format every loaded cell. The formatted text is now kept per tab and the switch no longer
/// reports a content change, so the guard here is that a tab still comes back with its own rows
/// rather than blank or holding the other tab's.
final class WarmTabSwitchUITests: UITestCase {
    func testAlternatingBetweenTwoLoadedTableTabsKeepsEachTabsOwnRows() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))

        openKeptTab("Album", in: window)
        let albumReadout = try settledReadout(in: window, describing: "Album")

        openKeptTab("Artist", in: window)
        let artistReadout = try settledReadout(in: window, describing: "Artist")

        XCTAssertNotEqual(
            albumReadout, artistReadout,
            "The two tables must differ in what their status bar reports, or the test cannot tell them apart"
        )

        for _ in 0..<3 {
            selectTab(titled: "Album", in: window)
            XCTAssertTrue(
                waitForPredicate(timeout: 15) { readout(in: window) == albumReadout },
                "Returning to Album must show Album's rows again, not a blank grid. Read: \(readout(in: window) ?? "nil")"
            )

            selectTab(titled: "Artist", in: window)
            XCTAssertTrue(
                waitForPredicate(timeout: 15) { readout(in: window) == artistReadout },
                "Returning to Artist must show Artist's rows again. Read: \(readout(in: window) ?? "nil")"
            )
        }
    }

    private func openKeptTab(_ table: String, in window: XCUIElement) {
        let row = objectBrowserRow(table, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(table)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
    }

    private func selectTab(titled title: String, in window: XCUIElement) {
        let tab = window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title))
            .firstMatch
        XCTAssertTrue(tab.waitToExist(timeout: 15), "The editor tab strip must carry a tab for \(title)")
        clickAtCenter(tab)
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
    }

    private func readout(in window: XCUIElement) -> String? {
        let element = window.staticTexts["result-status-readout"].firstMatch
        guard element.exists else { return nil }
        let text = (element.value as? String) ?? element.label
        return text.isEmpty ? nil : text
    }

    /// The readout is filled in stages as a table loads, and the polling is tight enough that an
    /// intermediate value can look stable across two of them. Settling is measured in wall clock
    /// instead: the same string has to survive a full second of samples.
    private func settledReadout(in window: XCUIElement, describing table: String) throws -> String {
        var previous: String?
        var stableSince = Date()
        XCTAssertTrue(
            waitForPredicate(timeout: 30) {
                let current = readout(in: window)
                if current != previous {
                    previous = current
                    stableSince = Date()
                    return false
                }
                return current != nil && Date().timeIntervalSince(stableSince) >= 1
            },
            "\(table) must finish loading before the switch test begins"
        )
        return try XCTUnwrap(readout(in: window))
    }
}
