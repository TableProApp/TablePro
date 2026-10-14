import XCTest

final class WelcomeConnectionListUITests: UITestCase {
    private let seededNames = ["delta-local", "alpha-staging", "charlie-prod"]

    func testTheConnectionListShowsFavoritesAndCancelsARename() throws {
        try seedSQLiteSession(seededNames.map { ConnectionSeed(name: $0, tabs: [], isOpen: false) })
        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 15))
        let list = welcomeConnectionList(in: welcome)
        XCTAssertTrue(list.waitToExist(timeout: 15), "The welcome window must show the connection list")
        for name in seededNames {
            XCTAssertTrue(welcomeConnectionRow(named: name, in: list).waitToExist(timeout: 10), "\(name) must be listed")
        }

        let favorite = welcomeConnectionRow(named: "charlie-prod", in: list)
        XCTAssertTrue(waitUntilHittable(favorite, timeout: 10))
        favorite.rightClick()
        let addToFavorites = contextMenuItem("Add to Favorites", in: app)
        XCTAssertTrue(waitUntilHittable(addToFavorites, timeout: 5))
        addToFavorites.click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.welcomeConnectionRows(named: "charlie-prod", in: list).count == 2 },
            "A favorite must show in Favorites and still in its place"
        )

        let renamed = welcomeConnectionRow(named: "alpha-staging", in: list)
        XCTAssertTrue(waitUntilHittable(renamed, timeout: 10))
        renamed.rightClick()
        let rename = contextMenuItem("Rename", in: app)
        XCTAssertTrue(waitUntilHittable(rename, timeout: 5))
        rename.click()
        let field = list.textFields["welcome-rename-field"]
        XCTAssertTrue(field.waitToExist(timeout: 5), "Rename must put the name in an editable field")
        app.typeText("renamed-by-test")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(waitForPredicate(timeout: 5) { !field.exists }, "Escape must end editing")
        XCTAssertTrue(welcomeConnectionRow(named: "alpha-staging", in: list).waitToExist(timeout: 5))
        XCTAssertFalse(
            welcomeConnectionRow(named: "renamed-by-test", in: list).exists,
            "Escape must keep the old name"
        )
    }
}
