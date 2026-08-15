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
    private var sandboxRoot: URL?
    private var launchedApps: [XCUIApplication] = []

    override internal func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sandboxRoot = root
    }

    /// Terminating before removing the directory matters: the app writes on the way down, and a
    /// directory deleted underneath it would let those writes fail into somewhere unexamined.
    override internal func tearDownWithError() throws {
        for app in launchedApps where app.state != .notRunning {
            app.terminate()
        }
        launchedApps.removeAll()

        if let sandboxRoot {
            try? FileManager.default.removeItem(at: sandboxRoot)
            removeDefaultsSuite(forSandboxAt: sandboxRoot)
        }
        sandboxRoot = nil
        try super.tearDownWithError()
    }

    internal func launchApp() throws -> XCUIApplication {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launchEnvironment["TABLEPRO_UI_TEST_SANDBOX"] = root.path
        app.launch()
        launchedApps.append(app)
        return app
    }

    /// The sample database is opened from the Help menu. Three suites used to reach for File, which
    /// has never carried this item, so they failed on any machine rather than flakily.
    @discardableResult
    internal func launchWithSampleDatabase() throws -> XCUIApplication {
        let app = try launchApp()
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 10))
        menuBar.menuBarItems["Help"].click()
        let openSample = menuBar.menuItems["Open Sample Database"]
        XCTAssertTrue(openSample.waitForExistence(timeout: 5))
        openSample.click()
        return app
    }

    /// A defaults suite is a file in the user's preferences directory, so removing the sandbox
    /// directory alone would leave one behind for every test that ever ran.
    private func removeDefaultsSuite(forSandboxAt root: URL) {
        UITestCase.removeSuite(named: "com.TablePro.uitest.\(root.lastPathComponent)")
    }

    /// `cfprefsd` writes a suite's plist lazily, so the per-test removal above can run before the
    /// file exists and miss it. Sweeping the whole namespace once the class is done catches those,
    /// and any left behind by a run that crashed before its teardown.
    override internal class func tearDown() {
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        for name in names where name.hasPrefix("com.TablePro.uitest.") && name.hasSuffix(".plist") {
            removeSuite(named: String(name.dropLast(".plist".count)))
        }
        super.tearDown()
    }

    private static func removeSuite(named suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
