import AppKit
import XCTest

/// Reopen Closed Tab took the closed tab out of its history and opened nothing whenever the
/// connection's window still had other tabs, which is the ordinary case: close one of several
/// tabs, then press Command-Shift-T.
final class ReopenClosedTabUITests: UITestCase {
    func testReopeningAClosedTableTabBringsItBackSelected() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)

        doubleClick(row("Album", in: window))
        doubleClick(row("Artist", in: window))
        let artist = tab(named: "Artist", in: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.tab(named: "Album", in: window).exists && artist.isSelected },
            "Album and Artist must both be open, with Artist selected, before one is closed"
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !artist.exists },
            "Close Tab must take the selected Artist tab out of the strip"
        )

        app.typeKey("t", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { artist.exists && artist.isSelected },
            "Reopen Closed Tab must bring the Artist tab back and select it"
        )
    }

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }

    private func row(_ name: String, in window: XCUIElement) -> XCUIElement {
        let match = objectBrowserRow(name, in: window)
        XCTAssertTrue(match.waitToExist(timeout: 20), "The object browser must list \(name)")
        return match
    }

    private func tab(named name: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)
            .matching(identifier: "editor-tab")
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
    }

    /// Waited out after the double-click, so the next click is not coalesced into it.
    private func doubleClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
    }
}
