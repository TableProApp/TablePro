//
//  LandingScreenshotTests.swift
//  TableProScreenshots
//

import XCTest

/// One test per file tablepro-web ships. The names match the files: `app-light.png` is the hero,
/// `sql-editor-dark.png` is row 01 of the workbench section, and so on. Renaming a test renames
/// the asset, which the site's ImageAssetsTest will then fail on.
final class LandingScreenshotTests: ScreenshotCase {
    func testHeroLight() throws {
        try captureHero(.light)
    }

    func testHeroDark() throws {
        try captureHero(.dark)
    }

    func testSqlEditorLight() throws {
        try captureSqlEditor(.light)
    }

    func testSqlEditorDark() throws {
        try captureSqlEditor(.dark)
    }

    func testDataGridLight() throws {
        try captureDataGrid(.light)
    }

    func testDataGridDark() throws {
        try captureDataGrid(.dark)
    }

    /// The hero is the orders table in the grid. It is the first thing anyone sees, and rows of
    /// real data say more about the app than an empty editor does.
    private func captureHero(_ appearance: Appearance) throws {
        let app = try launchForScreenshot(appearance: appearance, connections: [.mariadb])
        let window = openFirstConnection(in: app)
        openTable("orders", in: window)
        try capture(window, named: "app-\(appearance.rawValue)")
    }

    /// Two statements, because the copy beside this shot says a batch runs in one transaction and
    /// names the statement that fails. One SELECT would not show what that sentence describes.
    private func captureSqlEditor(_ appearance: Appearance) throws {
        let app = try launchForScreenshot(appearance: appearance, connections: [.postgres])
        let window = openFirstConnection(in: app)
        runQuery(Self.batch, in: app, window: window)
        try capture(window, named: "sql-editor-\(appearance.rawValue)")
    }

    /// The copy beside this shot says edits queue in memory until you save, and names the count in
    /// the toolbar. So this one edits a cell and stops there: the changed value sits in the grid,
    /// Save Changes turns from grey to live, and nothing has reached the database. The old shot
    /// showed a filter bar instead, which is a different sentence.
    private func captureDataGrid(_ appearance: Appearance) throws {
        let app = try launchForScreenshot(appearance: appearance, connections: [.mariadb])
        let window = openFirstConnection(in: app)
        openTable("orders", in: window)
        editTotal(in: window, to: "249.00")
        try capture(window, named: "data-grid-\(appearance.rawValue)")
    }

    private func editTotal(in window: XCUIElement, to value: String) {
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 20))

        /// 0.27 across is the `total` column and 0.18 down is the fifth row. Measured off a capture
        /// rather than guessed: 0.10 lands in `user_id`, and a decimal typed into an integer column
        /// is the kind of detail a reader notices and the app would not have accepted.
        let cell = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.18))
        cell.doubleClick()
        cell.doubleClick()

        let save = window.buttons["Save Changes"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "No Save Changes button in the toolbar")

        window.typeText(value)
        window.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { save.isEnabled },
            "The edit did not queue: Save Changes is still disabled"
        )
    }

    private static let batch = """
    SELECT u.name, u.email, u.plan,
           COUNT(o.id) AS total_orders,
           SUM(o.total) AS lifetime_value,
           MAX(o.created_at) AS last_order
    FROM users u
    JOIN orders o ON o.user_id = u.id
    GROUP BY u.name, u.email, u.plan
    ORDER BY lifetime_value DESC;

    SELECT p.name AS product, p.category,
           SUM(oi.quantity) AS units_sold,
           SUM(oi.subtotal) AS revenue
    FROM products p
    JOIN order_items oi ON oi.product_id = p.id
    GROUP BY p.name, p.category
    ORDER BY revenue DESC;
    """
}
