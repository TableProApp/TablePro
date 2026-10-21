import XCTest

// Two related tables picked on the ER diagram build a join whose condition comes from their foreign key,
// and the query lands in a new query tab with nothing typed.
final class JoinBuilderUITests: UITestCase {
    func testBuildingAJoinFromTwoTablesPickedOnTheDiagram() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app

        XCTAssertTrue(app.menuBars.firstMatch.waitToExist(timeout: 20), "The app must publish its menu bar")
        objectBrowser(in: window).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.contextMenuItem("View ER Diagram", in: app).isHittable },
            "The sidebar's empty-area menu must offer View ER Diagram"
        )
        contextMenuItem("View ER Diagram", in: app).click()

        let canvas = window.scrollViews.matching(identifier: "er-diagram-canvas").firstMatch
        XCTAssertTrue(canvas.waitToExist(timeout: 30), "The ER diagram must open on the fixture")
        let tables = canvas.descendants(matching: .layoutItem)
        let album = tables.matching(NSPredicate(format: "label == %@", "album")).firstMatch
        let artist = tables.matching(NSPredicate(format: "label == %@", "artist")).firstMatch
        XCTAssertTrue(album.waitToExist(timeout: 30), "The diagram must draw the album table")
        XCTAssertTrue(artist.waitToExist(timeout: 10), "The diagram must draw the artist table")

        album.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { album.isSelected }, "A click must select the album table")
        XCUIElement.perform(withKeyModifiers: .command) {
            artist.click()
        }
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { album.isSelected && artist.isSelected },
            "A Command-click must add the artist table to the selection"
        )

        let build = window.buttons.matching(identifier: "er-diagram-build-join").firstMatch
        XCTAssertTrue(build.waitToExist(timeout: 10), "The diagram must offer Build Join Query")
        build.click()

        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 10), "Build Join Query must open its sheet")
        let open = sheet.buttons.matching(identifier: "join-builder-open").firstMatch
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { open.exists && open.isEnabled && open.isHittable },
            "The builder must read the schema and offer the query"
        )
        open.click()

        let editor = editorTextView(in: window)
        let condition = "JOIN `artist` ON `album`.`artist_id` = `artist`.`id`"
        XCTAssertTrue(
            waitForEditorText(editor, timeout: 20) { $0.contains("FROM `album`") && $0.contains(condition) },
            "The new query tab must hold the join on album's foreign key, got: \(editorText(editor))"
        )
    }
}
