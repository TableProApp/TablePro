import XCTest

final class ForeignKeyNavigationUITests: UITestCase {
    // album opens from the object browser as a preview tab, the kind a reference used to retarget.
    func testFollowingAReferenceKeepsTheTabItCameFrom() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app
        let grid = openFromObjectBrowser("album", in: launch)
        let tabsBefore = editorTabCount(in: window)

        grid.clickCell(row: 1, column: 2)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])

        let openArtist = window.buttons["Open artist"].firstMatch
        XCTAssertTrue(openArtist.waitToExist(timeout: 30), "Preview FK Reference must offer to open artist")
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { openArtist.isEnabled },
            "The preview must load the referenced row before it can be opened"
        )
        clickAtCenter(openArtist)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { self.tabsTitled("artist", in: window).firstMatch.exists },
            "Following the reference must open artist in a tab"
        )
        XCTAssertGreaterThan(
            editorTabCount(in: window),
            tabsBefore,
            "Following the reference must add a tab rather than retarget the one it came from"
        )
        XCTAssertTrue(
            tabsTitled("album", in: window).firstMatch.exists,
            "The album tab must still be in the strip"
        )
    }
}
