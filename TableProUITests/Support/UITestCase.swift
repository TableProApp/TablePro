import TableProPluginKit
import XCTest

/// The base every UI test builds on, and the only supported way to get a running app.
///
/// A UI test drives the real app against real storage unless something redirects it, and this
/// project has already paid for that: a suite left stray connections in the developer's own store,
/// and because `startupBehavior` defaults to reopening the last session, launching the app under
/// test restored and connected to a production database over an SSH tunnel.
///
/// `launchApp()` hands the app a throwaway directory that lives for one test. The app resolves its
/// Application Support root, its defaults domain and its keychain from it, so nothing a test does
/// can reach the real ones, and nothing it leaves behind outlives the run.
internal class UITestCase: XCTestCase {
    internal private(set) var sandboxRoot: URL?
    private var launchedApps: [XCUIApplication] = []
    private var privacyAlertMonitor: (any NSObjectProtocol)?

    override internal func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        privacyAlertMonitor = addPrivacyAlertMonitor()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sandboxRoot = root
        /// Every run shares one defaults domain, so emptying it here is what keeps one test from
        /// reading what the last one wrote.
        UserDefaults.standard.removePersistentDomain(forName: PluginHostStorage.sandboxSuiteName)
    }

    /// Terminating before removing the directory matters: the app writes on the way down, and a
    /// directory deleted underneath it would let those writes fail into somewhere unexamined.
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

    /// macOS raises its local-network privacy alert over the app under test, and XCTest's built-in
    /// handler misses it: that matcher keys on the wording "would like to find", which macOS 26
    /// rewrote to "Allow ... to find devices on local networks?". Nothing dismissed it, so every
    /// element lookup for the rest of the test paid a full interruption sweep, which cost one suite
    /// ten minutes of a forty minute job. Matching on the buttons rather than the title keeps this
    /// working through the next rewording. Nothing under test needs the local network.
    private func addPrivacyAlertMonitor() -> any NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "System privacy alert") { alert in
            for label in ["Don't Allow", "Deny", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].click()
                return true
            }
            return false
        }
    }

    /// A UI test that fails only on CI is undiagnosable from a log line: the assertion says what
    /// was not found, never what was there instead. The tree is captured here so the result bundle
    /// the workflow already uploads carries it, which is the difference between reading a runner
    /// failure and guessing at it.
    private func attachElementTreeIfFailed() {
        guard let run = testRun, run.failureCount + run.unexpectedExceptionCount > 0 else { return }
        for (index, app) in launchedApps.enumerated() {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "element-tree-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// `arguments` is separate from `environment` because the two are not interchangeable. A
    /// defaults override such as `-AppleLanguages` only takes effect as a launch argument: passed
    /// in the environment it is an ordinary variable nothing reads, so the pin silently does
    /// nothing and the test passes only on a machine that was already in that language.
    internal func launchApp(
        environment: [String: String] = [:],
        arguments: [String] = []
    ) throws -> XCUIApplication {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launchEnvironment["TABLEPRO_UI_TEST_SANDBOX"] = root.path
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launchArguments.append(contentsOf: arguments)
        app.launch()
        launchedApps.append(app)
        return app
    }

    /// Asks for the sample database at launch instead of clicking `Help > Open Sample Database`.
    ///
    /// The menu route cost ten seconds on every call. XCUITest resolves a menu item by opening its
    /// parent, and a probe that resolved the item first left the menu open, so the click's own
    /// traversal failed with "open menu during menu traversal", waited out a ten second watchdog,
    /// snapshotted the whole accessibility hierarchy and only then retried. Every one of the 66
    /// tests that opened the sample paid it: 11 minutes of a 39 minute suite. None of those tests
    /// is about the Help menu, so they no longer go through it.
    ///
    /// `SingleWindowMenuContractUITests.testHelpMenuOpensTheSampleDatabase` still drives the menu
    /// item the way a person does, so the route keeps its coverage.
    ///
    /// The variable is read by `UITestLaunchEnvironment` in the app, which turns it into an
    /// ordinary `LaunchIntent`. Both sides spell it out because a UI test target cannot import the
    /// app, the same as `TABLEPRO_UI_TESTING` below.
    @discardableResult
    internal func launchWithSampleDatabase(
        environment: [String: String] = [:],
        arguments: [String] = []
    ) throws -> XCUIApplication {
        var launchEnvironment = environment
        launchEnvironment["TABLEPRO_UI_TEST_OPEN_SAMPLE"] = "1"
        let app = try launchApp(environment: launchEnvironment, arguments: arguments)
        XCTAssertTrue(
            waitForSampleDatabaseWindow(in: app),
            "The sample database never finished opening"
        )
        return app
    }

    /// Returning as soon as the launch was requested is what used to leave fourteen suites poking
    /// at a window that had no connection yet, and every one of those misses cost an XCUITest
    /// retry. The object browser having rows is the cheapest proof the connection is live.
    ///
    /// The query is built once and asks only whether a first match exists. Rebuilding
    /// `app.windows.firstMatch.outlines.firstMatch` inside the poll re-resolves the chain from the
    /// application element on every iteration, and `staticTexts.count` enumerates every static text
    /// under the outline rather than stopping at the first. Together they cost seconds per
    /// iteration once the window holds a loaded grid, so the timeout expires against the query
    /// instead of against the app, and the failure reads as a launch that never finished.
    /// The timeout is contention headroom, not a guess at how long opening takes. Three UI shards
    /// share a runner with the unit job and both arch builds, and the tests that miss the window
    /// are different on every run: this release's tag build lost `testTheBannerCanBeDismissed`,
    /// `testSwitchConnectionOpensWithTheToolbarHidden` and
    /// `testToggleFoldRunsWithTheCursorInsideAStatement`, and earlier runs lost an unrelated set.
    /// A suite that reports a launch failure because a sibling shard had the CPU is measuring the
    /// runner. Locally the wait settles in about two seconds, so the extra ceiling costs nothing
    /// on a machine that is not starved.
    internal func waitForSampleDatabaseWindow(in app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        let firstObject = app.children(matching: .window).firstMatch
            .descendants(matching: .outline).firstMatch
            .descendants(matching: .staticText).firstMatch
        return waitForPredicate(timeout: timeout) { firstObject.exists }
    }

    /// Opens the sample database the way a person does. Only the menu contract suite needs this;
    /// everything else takes the launch route above.
    @discardableResult
    internal func launchAndOpenSampleDatabaseFromHelpMenu() throws -> XCUIApplication {
        let app = try launchApp()
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuItems["Open Sample Database"].click()
        return app
    }

    internal func waitForPredicate(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        UITestPoll.until(timeout: timeout, condition)
    }

    /// The precondition a click actually has. `waitForExistence` only says the element is in the
    /// tree, which a row inside a pane that is still animating open already is; the click then
    /// lands on a moving target, the app hit-tests the point to nothing, and the event goes
    /// nowhere with no failure of its own. `isHittable` is the question AppKit can answer: does
    /// this point come back to this element. Nothing in the app can defend against the early
    /// click, because animating a pane into place is what AppKit does.
    internal func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForPredicate(timeout: timeout) { element.exists && element.isHittable }
    }

    /// Switches the result to its Structure editor, through **View > Result View > Structure**
    /// rather than the `Structure` segment of the results status bar.
    ///
    /// The segment cannot be clicked on the runner. Its screen is 1024x768, and a window that
    /// wide cannot hold the sidebar, the detail pane at its minimum width and the row inspector
    /// at once: the detail pane keeps its minimum and is drawn under the sidebar, taking the
    /// leading half of the status bar with it. XCUITest still reports the segment as existing and
    /// hittable, because its accessibility frame is where the layout says it is, so the click is
    /// posted at (314, 691) and lands on the sidebar. Nothing fails there. The result stays on
    /// Data, and the suite's next assertion reads the data grid as though it were the structure
    /// grid, or waits out its timeout for a structure tab picker that was never going to appear.
    /// (Run 33734073855, where the element tree captured the mode picker still reporting
    /// `Data` selected after the click.)
    ///
    /// The menu item carries no geometry, so it is reachable whatever the window is doing.
    /// Nothing probes for it first: XCUITest resolves a menu item by opening its parent, and a
    /// probe that resolves it leaves that menu open, so the click's own traversal then fails with
    /// "open menu during menu traversal" and waits out a ten second watchdog. Waiting on the menu
    /// bar costs nothing and waiting for the tab picker afterwards is what makes the switch
    /// observed rather than assumed.
    internal func showStructure(in app: XCUIApplication, window: XCUIElement) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 20), "The app must publish its menu bar")
        menuBar.menuItems["Structure"].click()
        XCTAssertTrue(
            window.radioGroups["structure-tab-picker"].firstMatch.waitToExist(timeout: 30),
            "The structure editor must open on the Structure result view"
        )
    }

    /// A point inside the data grid that an overlapping pane cannot steal.
    ///
    /// A coordinate is the only way to click a row at all: the grid's columns are siblings of its
    /// rows and later in the tree, so XCUITest reads every row and every cell as obscured and
    /// refuses to click either. The grid's leading edge is not safe to measure from, though. On
    /// the runner the detail pane is drawn under the sidebar, so a point 80pt in from that edge
    /// lands on the object browser and a right-click raises its menu rather than the grid's.
    /// Starting from whichever edge is further right keeps the point on the grid at any width.
    internal func gridPoint(in grid: XCUIElement, of window: XCUIElement, dy: CGFloat) -> XCUICoordinate {
        let clearOfBrowser = window.outlines.firstMatch.frame.maxX + 40 - grid.frame.minX
        return grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: max(80, clearOfBrowser), dy: dy))
    }

    /// The object browser draws its rows as hosted cells, so a row's name arrives as the static
    /// text's `value`, carrying the object kind the row reads out to VoiceOver, rather than as a
    /// label or an identifier. Matching on `value` is what finds them.
    internal func objectBrowserRow(
        _ name: String,
        kind: String = "Table",
        in window: XCUIElement
    ) -> XCUIElement {
        window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "\(kind): \(name)"))
            .firstMatch
    }

    /// The query editor's text view. Eighteen suites carried a byte-identical private copy of this
    /// before it moved here.
    ///
    /// The identifier branch is the specific query and the `firstMatch` fallback is what actually
    /// resolves today, because the identifier is applied to the SwiftUI representable rather than
    /// to the `NSTextView` underneath it. Both are kept: the fallback is what works, and the
    /// identified lookup is what should start working the day the identifier reaches the text view.
    internal func editorTextView(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let identified = window.textViews.matching(identifier: "sql-editor-textview").firstMatch
        if identified.exists {
            return identified
        }
        return window.textViews.firstMatch
    }

    /// AppKit reports those rows as disabled, so they never become hittable and a plain `click()`
    /// waits for a state that cannot arrive. Clicking through a coordinate reaches them.
    internal func clickAtCenter(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// An item of the contextual menu a right-click just raised, picked out from the menu bar's
    /// copy of the same title.
    ///
    /// A closed menu bar submenu is still in the accessibility tree, so an app-rooted
    /// `menuItems[title]` matches **Database > Copy To…** as readily as the menu under the pointer
    /// and then refuses to click either. Hittability is what separates them: only the open menu's
    /// items can be clicked.
    ///
    /// Scoping by container does not work here, measured: `app.children(matching: .menu)` is empty
    /// while a contextual menu is up, so a query built on it silently answers no. That is why this
    /// takes a title the menu bar also has and narrows it, rather than asking a container what it
    /// holds. **A negative assertion cannot be written this way at all**: an absent contextual
    /// item is indistinguishable from a present-but-unhittable menu bar one. Assert the absence in
    /// a unit test over the menu-building code instead.
    internal func contextMenuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.menuItems.matching(NSPredicate(format: "title == %@", title))
        return matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
    }

    /// The app removes its own defaults domain as it terminates, which is the only point that
    /// reliably comes after `cfprefsd` has written it. This sweep is the backstop for a run that
    /// crashed or was killed before it got there, and it runs before the class's tests so a
    /// previous session's leftovers go too.
    override internal class func setUp() {
        super.setUp()
        sweepLeftoverSuites()
    }

    override internal class func tearDown() {
        sweepLeftoverSuites()
        super.tearDown()
    }

    private static func sweepLeftoverSuites() {
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        for name in names where name.hasPrefix("com.TablePro.uitest") && name.hasSuffix(".plist") {
            removeSuite(named: String(name.dropLast(".plist".count)))
        }
    }

    private static func removeSuite(named suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
