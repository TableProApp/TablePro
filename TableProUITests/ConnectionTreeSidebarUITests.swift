import XCTest

/// The sidebar lists every saved connection, not only the ones this window has open.
///
/// The connections are written into the sandbox before launch rather than driven through the UI:
/// a store with no integrity tag beside it is adopted as it stands, which is the path an install
/// predating the tag takes, so a test can seed one without the app's own writer.
///
/// They are seeded ungrouped on purpose. Groups live in a `UserDefaults` suite, the runner is
/// sandboxed and the app is not, so the suite resolves to two different files and nothing this
/// process writes there is ever read by the app. `ConnectionTreeRootBuilderTests` covers grouping.
///
/// The sample database supplies the window. The tree belongs to a main window, so on the welcome
/// screen there is no sidebar to find it in.
final class ConnectionTreeSidebarUITests: UITestCase {
    private let seededNames = ["acme-orders", "acme-billing", "acme-analytics"]

    func testSidebarListsEverySavedConnection() throws {
        try seedConnections()
        let app = try launchWithSampleDatabase()

        let tree = app.outlines["connection-tree"].firstMatch
        XCTAssertTrue(tree.waitToExist(timeout: 20), "The connections tree never appeared in the sidebar")

        for name in seededNames {
            XCTAssertTrue(
                tree.staticTexts[name].waitToExist(timeout: 10),
                "The connections tree is missing the saved connection \(name)"
            )
        }
    }

    /// A saved connection the window has not opened still gets a row. That is the whole difference
    /// from the workspace rail, which listed only what was already open.
    func testUnopenedConnectionsAreListedBesideTheOpenOne() throws {
        try seedConnections()
        let app = try launchWithSampleDatabase()

        let tree = app.outlines["connection-tree"].firstMatch
        XCTAssertTrue(tree.waitToExist(timeout: 20), "The connections tree never appeared in the sidebar")
        XCTAssertTrue(
            tree.staticTexts[seededNames[0]].waitToExist(timeout: 10),
            "A connection this window never opened is missing from the tree"
        )
        XCTAssertGreaterThanOrEqual(
            tree.staticTexts.count,
            seededNames.count,
            "The tree shows fewer rows than the store holds"
        )
    }

    private func seedConnections() throws {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let connections = seededNames.enumerated().map {
            connectionPayload(name: $0.element, sortOrder: $0.offset)
        }
        try JSONSerialization.data(withJSONObject: connections, options: [.sortedKeys])
            .write(to: supportDirectory.appendingPathComponent("connections.json"), options: .atomic)
    }

    /// Every key the stored form decodes without a default. A key added there without one fails
    /// this test rather than silently seeding nothing, which is also the key every store already on
    /// a user's disk would be missing.
    private func connectionPayload(name: String, sortOrder: Int) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "name": name,
            "host": "127.0.0.1",
            "port": 3_306,
            "database": "app",
            "username": "root",
            "type": "MySQL",
            "sshEnabled": false,
            "sshHost": "",
            "sshUsername": "",
            "sshAuthMethod": "password",
            "sshPrivateKeyPath": "",
            "sortOrder": sortOrder,
        ]
    }
}
