import XCTest

/// The only way a UI test gets a running app: every launch names a sandbox, so the app never touches the real store.
internal class UITestCase: XCTestCase {
    internal private(set) var sandboxRoot: URL?
    private var launchedApps: [XCUIApplication] = []
    private var privacyAlertMonitor: (any NSObjectProtocol)?

    // One path per checkout: the app names its defaults suite after the path and empties it when the
    // directory is new, so each test starts clean and a worktree never shares a suite with another.
    private static var sandboxLocation: URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Bundle(for: UITestCase.self).bundlePath.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProUITests", isDirectory: true)
            .appendingPathComponent(String(hash, radix: 16), isDirectory: true)
    }

    override internal func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        privacyAlertMonitor = addPrivacyAlertMonitor()

        let root = Self.sandboxLocation
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sandboxRoot = root
    }

    // Terminate first: the app writes on the way down, and those writes must land inside the sandbox.
    override internal func tearDownWithError() throws {
        attachElementTreeIfFailed()
        for app in launchedApps where app.state != .notRunning {
            app.terminate()
        }
        launchedApps.removeAll()

        if let sandboxRoot {
            try? FileManager.default.removeItem(at: sandboxRoot)
        }
        sandboxRoot = nil
        if let privacyAlertMonitor {
            removeUIInterruptionMonitor(privacyAlertMonitor)
        }
        privacyAlertMonitor = nil
        try super.tearDownWithError()
    }

    // XCTest's own handler misses macOS 26's local-network alert ("Allow ... to find devices"), and an
    // undismissed alert makes every later query pay an interruption sweep. Matching buttons survives rewording.
    private func addPrivacyAlertMonitor() -> any NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "System privacy alert") { alert in
            for label in ["Don't Allow", "Deny", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].click()
                return true
            }
            return false
        }
    }

    // An assertion says what was missing, never what was there; the tree in the result bundle does.
    private func attachElementTreeIfFailed() {
        guard let run = testRun, run.failureCount + run.unexpectedExceptionCount > 0 else { return }
        for (index, app) in launchedApps.enumerated() {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "element-tree-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: - Launching

    /// A defaults override such as `-AppleLanguages` only works as a launch argument, never in `environment`.
    internal func launchApp(
        environment: [String: String] = [:],
        arguments: [String] = []
    ) throws -> XCUIApplication {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launchEnvironment["TABLEPRO_UI_TEST_SANDBOX"] = root.path
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        launchedApps.append(app)
        return app
    }

    /// Restores `seeds` as the last session, so the window opens already connected.
    ///
    /// An intent variable (`TABLEPRO_UI_TEST_OPEN_*`) in `environment` skips the session restore;
    /// use `launchWithFixture(openingDataFile:contents:)` to pair the fixture with a data file.
    @discardableResult
    internal func launchWithFixture(
        _ seeds: [ConnectionSeed] = [ConnectionSeed()],
        environment: [String: String] = [:],
        arguments: [String] = []
    ) throws -> FixtureLaunch {
        let connections = try seedSQLiteSession(seeds)
        let app = try launchApp(environment: environment, arguments: arguments)
        let window = mainWindow(in: app)
        XCTAssertTrue(waitForObjectBrowser(in: window), "The fixture connection never listed its tables")
        return FixtureLaunch(app: app, window: window, connections: connections)
    }

    /// Opens a data file window the way a Finder double-click does.
    internal func launchWithDataFile(named name: String, contents: Data) throws -> XCUIApplication {
        let fileURL = try writeIntoSandbox(name, contents: contents)
        return try launchApp(environment: ["TABLEPRO_UI_TEST_OPEN_FILE": fileURL.path])
    }

    /// Arrives as the intent a Finder double-click on a `.tablepro` file sends.
    internal func launchWithConnectionShare(named name: String, contents: Data) throws -> XCUIApplication {
        let fileURL = try writeIntoSandbox(name, contents: contents)
        return try launchApp(environment: ["TABLEPRO_UI_TEST_OPEN_CONNECTION_SHARE": fileURL.path])
    }

    /// Reaches the app's own URL handling, never another installed copy registered for the scheme.
    internal func launchOpeningURL(_ url: String, arguments: [String] = []) throws -> XCUIApplication {
        try launchApp(environment: ["TABLEPRO_UI_TEST_OPEN_URL": url], arguments: arguments)
    }

    internal func writeIntoSandbox(_ name: String, contents: Data) throws -> URL {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let fileURL = root.appendingPathComponent(name)
        try contents.write(to: fileURL)
        return fileURL
    }

    // MARK: - Finding things

    /// A window is a direct child of the application; `app.windows` walks the whole tree to find one.
    internal func window(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.children(matching: .window).matching(identifier: identifier).firstMatch
    }

    internal func mainWindow(in app: XCUIApplication) -> XCUIElement {
        window("main", in: app)
    }

    internal func welcomeWindow(in app: XCUIApplication) -> XCUIElement {
        window("welcome", in: app)
    }

    // A descendants search from the window reaches the data grid while the sidebar is still a spinner,
    // and walking a loaded grid costs seconds on the app's main thread. Direct children keep a miss cheap.
    internal func objectBrowser(in window: XCUIElement) -> XCUIElement {
        window.children(matching: .splitGroup).firstMatch
            .children(matching: .group).firstMatch
            .descendants(matching: .outline).firstMatch
    }

    /// The cheapest proof a connection is live: its object browser lists something.
    internal func waitForObjectBrowser(in window: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let firstObject = objectBrowser(in: window).descendants(matching: .staticText).firstMatch
        return waitForPredicate(timeout: timeout) { firstObject.exists }
    }

    /// Hosted cells publish the row's name as the static text's `value`, prefixed with its kind.
    internal func objectBrowserRow(_ name: String, kind: String = "Table", in window: XCUIElement) -> XCUIElement {
        objectBrowser(in: window).staticTexts
            .matching(NSPredicate(format: "value == %@", "\(kind): \(name)"))
            .firstMatch
    }

    internal func dataGrid(in window: XCUIElement) -> XCUIElement {
        window.tables.matching(identifier: "data-grid").firstMatch
    }

    // The identifier sits on the SwiftUI representable, not on the NSTextView, so it never resolves.
    internal func editorTextView(in window: XCUIElement) -> XCUIElement {
        window.textViews.firstMatch
    }

    /// Keystrokes typed before the editor installs its key monitor are lost, so this retypes until the text arrives.
    internal func typeQuery(_ sql: String, in window: XCUIElement, attempts: Int = 3) {
        let editor = editorTextView(in: window)
        XCTAssertTrue(editor.waitToExist(timeout: 10), "The query tab must hold an editor to type into")
        for _ in 0 ..< attempts {
            editor.click()
            editor.typeKey("a", modifierFlags: .command)
            editor.typeText(sql)
            let arrived = waitForPredicate(timeout: 3) {
                ((editor.value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == sql
            }
            if arrived { return }
        }
        XCTFail("The editor never received the query typed into it")
    }

    /// An item of the contextual menu a right-click just raised; the menu bar's closed copy of the
    /// same title is never hittable. Assert an absent contextual item in a unit test instead.
    internal func contextMenuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.menuItems.matching(NSPredicate(format: "title == %@", title))
        return matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
    }

    // MARK: - Waiting

    internal func waitForPredicate(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        UITestPoll.until(timeout: timeout, condition)
    }

    /// Existence is not enough to click: a row in a pane still animating open hit-tests to nothing.
    internal func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForPredicate(timeout: timeout) { element.exists && element.isHittable }
    }

    // macOS clicks where an element is and never scrolls it into view. Scrolling a window posts at its
    // top-left corner, over the title bar, so the scroll goes to a point inside the content.
    internal func scrollUntilHittable(_ element: XCUIElement, in container: XCUIElement, timeout: TimeInterval) -> Bool {
        let content = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !(element.exists && element.isHittable) {
            guard Date() < deadline else { return false }
            content.scroll(byDeltaX: 0, deltaY: -400)
        }
        return true
    }

    // A grid enters the tree before its query returns, and a coordinate taken off an empty frame posts
    // at (inf, inf). `firstMatch` stops the walk; asking for every row mounts a cell for each.
    internal func waitForClickableRows(in grid: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let firstRow = grid.tableRows.firstMatch
        return waitForPredicate(timeout: timeout) {
            grid.frame.width > 0 && grid.frame.height > 0 && firstRow.exists
        }
    }

    // MARK: - Acting

    internal func isOn(_ toggle: XCUIElement) -> Bool {
        if let number = toggle.value as? Int { return number == 1 }
        return (toggle.value as? String) == "1"
    }

    // `hasFocus` does not reach Swift on macOS and raises through KVC. The first line of the element's
    // snapshot carries "Keyboard Focused"; later lines belong to its children.
    internal func holdsKeyboardFocus(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let ownAttributes = element.debugDescription
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return ownAttributes.contains("Keyboard Focused")
    }

    // Rows and cells read as obscured by their sibling columns, so a click goes through a coordinate.
    // On the 1024pt runner the sidebar overlaps the grid's leading edge, so start right of whichever is further.
    internal func gridPoint(in grid: XCUIElement, of window: XCUIElement, dy: CGFloat) -> XCUICoordinate {
        let clearOfBrowser = objectBrowser(in: window).frame.maxX + 40 - grid.frame.minX
        return grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: max(80, clearOfBrowser), dy: dy))
    }

    /// AppKit reports some rows as disabled, so they never become hittable; a coordinate click reaches them.
    internal func clickAtCenter(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// For a command with no key equivalent. Click it without probing: resolving the item opens its
    /// menu, and the click's own traversal then fails with "open menu during menu traversal".
    internal func menuItem(_ title: String, under menu: String, in app: XCUIApplication) -> XCUIElement {
        app.menuBars.firstMatch.menuBarItems[menu].menuItems[title].firstMatch
    }

    // The status-bar segment lands under the sidebar on the 1024x768 runner and the click silently
    // hits the sidebar, so the result view is switched from View > Result View.
    internal func showResultView(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.menuBars.firstMatch.waitToExist(timeout: 20), "The app must publish its menu bar")
        menuItem(title, under: "View", in: app).click()
    }

    internal func showStructure(in app: XCUIApplication, window: XCUIElement) {
        showResultView("Structure", in: app)
        XCTAssertTrue(
            window.radioGroups["structure-tab-picker"].firstMatch.waitToExist(timeout: 30),
            "The structure editor must open on the Structure result view"
        )
    }

    internal func showData(in app: XCUIApplication, window: XCUIElement) {
        showResultView("Data", in: app)
        XCTAssertTrue(dataGrid(in: window).waitToExist(timeout: 30), "The Data result view must show a grid")
    }
}

internal struct FixtureLaunch {
    internal let app: XCUIApplication
    internal let window: XCUIElement
    internal let connections: [SeededConnection]

    internal var database: URL {
        connections[0].database
    }
}
