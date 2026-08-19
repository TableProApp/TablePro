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
            removeDefaultsSuite(forSandboxAt: sandboxRoot)
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

    /// The sample database is opened from the Help menu. Three suites used to reach for File, which
    /// has never carried this item, so they failed on any machine rather than flakily.
    ///
    /// Never click the parent menu first. `click()` on a menu item runs its own menu traversal and
    /// opens the parent as part of it, so an already-open menu makes that traversal fail with "open
    /// menu during menu traversal"; XCUITest then falls back to hovering and resolves the item to an
    /// unhittable zero-size frame. That failed every suite this helper serves.
    @discardableResult
    internal func launchWithSampleDatabase(
        environment: [String: String] = [:],
        arguments: [String] = []
    ) throws -> XCUIApplication {
        let app = try launchApp(environment: environment, arguments: arguments)
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 10))
        let openSample = menuBar.menuItems["Open Sample Database"]
        XCTAssertTrue(openSample.waitForExistence(timeout: 10))
        openSample.click()
        return app
    }

    internal func waitForPredicate(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return condition()
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

    /// A defaults suite is a file in the user's preferences directory, so removing the sandbox
    /// directory alone would leave one behind for every test that ever ran.
    private func removeDefaultsSuite(forSandboxAt root: URL) {
        UITestCase.removeSuite(named: "com.TablePro.uitest.\(root.lastPathComponent)")
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
