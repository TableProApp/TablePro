import XCTest

// #2487: Copy To has to be on the object browser's own menu. The object search used to be a plain text
// field, so Escape went past it to the sheet's Cancel and threw away every choice made in the sheet.
final class CopyObjectsUITests: UITestCase {
    func testCopyToOpensFromTheRowMenuAndEscapeClearsTheSearchFirst() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app

        rightClickInObjectBrowser("album", in: window)
        let copyTo = contextMenuItem("Copy To…", in: app)
        XCTAssertTrue(copyTo.waitToExist(timeout: 10), "Copy To must be on a table row's contextual menu")
        copyTo.click()

        // A direct child, so no lookup walks the window behind the sheet.
        let sheet = window.children(matching: .sheet).firstMatch
        let objects = sheet.outlines.matching(identifier: "copy-objects-list").firstMatch
        XCTAssertTrue(objects.waitToExist(timeout: 20), "Copy To must open a sheet listing the objects to copy")

        let search = sheet.searchFields.matching(identifier: "copy-objects-search").firstMatch
        XCTAssertTrue(waitUntilHittable(search, timeout: 20), "The sheet must offer an object search")
        search.click()
        app.typeText("album")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (search.value as? String) == "album" },
            "Typing must reach the object search"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                guard search.exists else { return false }
                let text = (search.value as? String) ?? ""
                return text.isEmpty || text == search.placeholderValue
            },
            "Escape belongs to the search field while it holds text: it must clear it and leave the sheet open"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !sheet.exists },
            "Escape on an empty search field must close the sheet"
        )
    }
}
