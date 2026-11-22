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

    // AppKit publishes a toolbar item by its label, not its item identifier, so the items are found by name.
    func testTheToolbarFiltersByTagAndSearchesTheList() throws {
        try seedSQLiteSession([
            ConnectionSeed(name: "delta-local", tabs: [], isOpen: false, tagIds: [PresetTag.local]),
            ConnectionSeed(name: "alpha-staging", tabs: [], isOpen: false),
            ConnectionSeed(name: "charlie-prod", tabs: [], isOpen: false, tagIds: [PresetTag.production]),
        ])
        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 15))
        let list = welcomeConnectionList(in: welcome)
        let alpha = welcomeConnectionRow(named: "alpha-staging", in: list)
        let charlie = welcomeConnectionRow(named: "charlie-prod", in: list)
        XCTAssertTrue(alpha.waitToExist(timeout: 15))

        let toolbar = welcome.toolbars.firstMatch
        XCTAssertTrue(toolbar.buttons["New Connection"].waitToExist(timeout: 5), "The toolbar must offer New Connection")
        XCTAssertTrue(toolbar.buttons["New Group"].exists, "The toolbar must offer New Group")
        let viewOptions = toolbar.descendants(matching: .any).matching(identifier: "View Options").firstMatch
        XCTAssertTrue(waitUntilHittable(viewOptions, timeout: 5), "The toolbar must offer View Options")

        viewOptions.click()
        // View > Sort Connections By holds a closed copy of the item, so only the open menu's copy is hittable.
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.contextMenuItem("Database Type", in: app).isHittable },
            "View Options must list the sort orders"
        )
        let production = contextMenuItem("production", in: app)
        XCTAssertTrue(waitUntilHittable(production, timeout: 5), "View Options must list the tags in use")
        production.click()

        let bar = welcome.descendants(matching: .any).matching(identifier: "welcome-tag-filter-bar").firstMatch
        XCTAssertTrue(bar.waitToExist(timeout: 5), "A tag filter must show the filter bar")
        XCTAssertTrue(waitForPredicate(timeout: 5) { !alpha.exists }, "The tag filter must hide untagged rows")
        XCTAssertTrue(charlie.exists)
        let barTag = bar.buttons["production"]
        XCTAssertTrue(waitUntilHittable(barTag, timeout: 5))
        barTag.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !bar.exists && alpha.exists }, "Clicking the tag must stop filtering")

        app.typeShortcut(.find)
        let search = welcome.searchFields["welcome-toolbar-search"]
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.holdsKeyboardFocus(search) },
            "Find must put the keyboard in the toolbar's search field"
        )
        app.typeText("charlie")
        XCTAssertTrue(waitForPredicate(timeout: 5) { !alpha.exists }, "Typing must narrow the list")
        XCTAssertTrue(charlie.exists)

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { self.holdsKeyboardFocus(list) && charlie.isSelected },
            "Return must hand the list the keyboard with the first match selected"
        )
    }

    func testReturnOnASelectedConnectionOpensIt() throws {
        try seedSQLiteSession([ConnectionSeed(name: "alpha-staging", tabs: [], isOpen: false)])
        let app = try launchApp()
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(welcome.waitToExist(timeout: 15))
        let list = welcomeConnectionList(in: welcome)
        let row = welcomeConnectionRow(named: "alpha-staging", in: list)
        XCTAssertTrue(waitUntilHittable(row, timeout: 15))
        row.click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { self.holdsKeyboardFocus(list) }, "A click must give the list the keyboard")

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(mainWindow(in: app).waitToExist(timeout: 30), "Return must open the selected connection")
    }
}
