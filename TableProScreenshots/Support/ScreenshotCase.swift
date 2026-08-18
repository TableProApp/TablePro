//
//  ScreenshotCase.swift
//  TableProScreenshots
//

import AppKit
import XCTest

/// Drives the app to one state and writes a PNG that tablepro-web can ship without retouching.
///
/// This target is not in the `TablePro` scheme's test action. It needs the demo databases in
/// `demo/docker-compose.yml` running and it needs Screen Recording granted to whatever runs
/// `xcodebuild`, neither of which belongs in the test job that gates a pull request.
internal class ScreenshotCase: UITestCase {
    internal static let outputVariable = "TABLEPRO_SCREENSHOT_OUTPUT"

    /// 1512x861 points, which is 3024x1722 pixels on a 2x display. That is what every shot already
    /// on the site is, and the page declares those pixel counts as each image's width and height,
    /// so a capture at another size changes the box the section reserves while the file loads.
    internal static let windowSize = CGSize(width: 1512, height: 861)
    internal static let pixelWidth = 3_024
    internal static let pixelHeight = 1_722

    internal enum Appearance: String {
        case light
        case dark
    }

    /// Seeded straight into the sandbox rather than typed into the connection form.
    /// `ConnectionStorage` treats a `connections.json` it has never stamped as an install that
    /// predates the tag, adopts it, and stamps it, so a written file is a supported starting state
    /// and not a hole in the integrity check.
    internal struct DemoConnection {
        internal let name: String
        internal let type: String
        internal let host: String
        internal let port: Int
        internal let database: String
        internal let username: String

        internal static let mariadb = DemoConnection(
            name: "Local",
            type: "MariaDB",
            host: "127.0.0.1",
            port: 53_306,
            database: "tablepro_demo",
            username: "root"
        )

        internal static let postgres = DemoConnection(
            name: "Local",
            type: "PostgreSQL",
            host: "127.0.0.1",
            port: 55_432,
            database: "tablepro_demo",
            username: "tablepro"
        )
    }

    /// Xcode signs the UI test runner itself, with the app sandbox on and a read-only exception
    /// for `/`. Setting `ENABLE_APP_SANDBOX: NO` on the target does not reach it, so the runner can
    /// read the whole disk and write only inside its own container. The default therefore lands in
    /// the container, and `announceOutputDirectory()` prints where that is so
    /// `scripts/export-screenshots.sh` can copy the files out instead of guessing the path.
    internal var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment[Self.outputVariable], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProScreenshots", isDirectory: true)
    }

    internal static let captureMarker = "TABLEPRO_CAPTURE_READY\t"

    @discardableResult
    internal func launchForScreenshot(
        appearance: Appearance,
        connections: [DemoConnection] = []
    ) throws -> XCUIApplication {
        if !connections.isEmpty {
            try seed(connections)
        }

        return try launchApp(environment: [
            ScreenshotEnvironmentNames.frame: "\(Int(Self.windowSize.width))x\(Int(Self.windowSize.height))",
            ScreenshotEnvironmentNames.appearance: appearance.rawValue,
            "AppleLanguages": "(en)",
        ])
    }

    /// A first launch opens the welcome window, which is 800x512 and is not the shot. Opening a
    /// connection is what creates the window `pinWindowSize` applies to, so every shot starts here.
    @discardableResult
    internal func openFirstConnection(in app: XCUIApplication) -> XCUIElement {
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 30), "The welcome window never appeared")

        /// The row itself reports Disabled, so `isHittable` is false on it and only the cell inside
        /// it can be clicked. Asking the row would wait out the timeout on a list that is there.
        let cell = welcome.outlines.firstMatch.cells.element(boundBy: 0)
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "The seeded connection is not in the list")
        cell.doubleClick()

        let main = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 60), "Opening the connection produced no window")
        return main
    }

    /// Sidebar rows report Disabled, same as the welcome list, so the label inside the row is the
    /// only part that takes a click.
    internal func openTable(_ table: String, in window: XCUIElement) {
        let label = window.staticTexts["Table: \(table)"]
        XCTAssertTrue(waitUntilHittable(label, timeout: 30), "No \(table) table in the sidebar")
        label.click()

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "Opening \(table) produced no grid")
        waitForViews(in: window)
    }

    /// The sidebar lists views after the tables, and it fills that section on its own schedule.
    /// A shot taken before it does has an empty Views heading, which reads as a database with no
    /// views rather than as a screenshot taken too early. Soft on purpose: if the section never
    /// fills the shot is still worth having, so this notes it and moves on.
    private func waitForViews(in window: XCUIElement) {
        let views = window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "View: "))
        if !waitForPredicate(timeout: 15, { views.firstMatch.exists }) {
            print("note: the Views section was still empty when the shot was taken")
            fflush(stdout)
        }
    }

    /// Pasted rather than typed. Typing a multi-statement query into an editor with autocomplete
    /// and auto-indent produces something nobody wrote, and the screenshot is of the query.
    internal func runQuery(_ sql: String, in app: XCUIApplication, window: XCUIElement) {
        /// Through the menu rather than Cmd+T. The keystroke needs the new window to already be
        /// key, and right after the welcome window closes it is not, so the editor never opened.
        /// Never click the File menu first: clicking a menu item runs its own traversal, and an
        /// already-open parent makes that traversal fail.
        let newTab = app.menuBars.menuItems["New Tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 20), "No New Tab item in the File menu")
        newTab.click()

        /// The identified lookup first, the bare one second, same as QueryHistoryPanelUITests.
        /// The text view carries `sql-editor-textview` in some states and only its `Text Editor`
        /// label in others, and a screenshot run is not the place to find out which.
        let identified = window.textViews.matching(identifier: "sql-editor-textview").firstMatch
        let editor = identified.waitForExistence(timeout: 5) ? identified : window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "New Tab opened no editor")
        editor.click()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
        app.typeKey("v", modifierFlags: .command)

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (editor.value as? String)?.contains("SELECT") == true },
            "The query never reached the editor"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.command, .shift])

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 45), "The query produced no result grid")
    }

    /// The capture itself runs outside this process.
    ///
    /// Xcode signs the UI test runner fresh on every build, and `screencapture` needs Screen
    /// Recording, which that identity does not have and cannot be given once and kept. The runner
    /// does have a read-only exception for the whole disk, so the split is: this prints the window
    /// number and where the file should go, `scripts/export-screenshots.sh` takes the picture, and
    /// this waits for the file and reads it back to check it. Nothing here is timed; the test waits
    /// for a file to exist, not for a duration to pass.
    @discardableResult
    internal func capture(_ window: XCUIElement, named name: String) throws -> URL {
        XCTAssertTrue(window.waitForExistence(timeout: 30), "No window to capture")

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { Self.matches(window.frame.size) },
            "Window is \(window.frame.size), expected \(Self.windowSize). The frame hook did not run."
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "\(outputDirectory.path) does not exist. Run this through scripts/export-screenshots.sh."
        )

        let number = try XCTUnwrap(
            mainWindowNumber(),
            "No on-screen window belongs to TablePro"
        )

        let destination = outputDirectory.appendingPathComponent("\(name).png")
        request(capture: name, window: number, to: destination)

        XCTAssertTrue(
            waitForPredicate(timeout: 60) { FileManager.default.fileExists(atPath: destination.path) },
            "Nothing captured \(name). Is this running under scripts/export-screenshots.sh?"
        )

        try assertShippable(destination)
        attach(destination, named: name)
        return destination
    }

    /// Flushed by hand. Left to itself this goes into a pipe, where stdio buffers it in blocks and
    /// the script reading the pipe would not see the line until the process had moved on.
    private func request(capture name: String, window number: CGWindowID, to destination: URL) {
        print("\(Self.captureMarker)\(name)\t\(number)\t\(destination.path)")
        fflush(stdout)
    }

    /// A point of slack, because AppKit rounds a centred origin and can hand back a frame half a
    /// point off without having refused the size.
    private static func matches(_ size: CGSize) -> Bool {
        abs(size.width - windowSize.width) < 1 && abs(size.height - windowSize.height) < 1
    }

    private func seed(_ connections: [DemoConnection]) throws {
        let root = try XCTUnwrap(sandboxRoot, "setUpWithError did not prepare a sandbox")
        let directory = root.appendingPathComponent("TablePro", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let payload = connections.enumerated().map { index, connection -> [String: Any] in
            [
                "id": UUID().uuidString,
                "name": connection.name,
                "host": connection.host,
                "port": connection.port,
                "database": connection.database,
                "username": connection.username,
                "type": connection.type,
                "sshEnabled": false,
                "sshHost": "",
                "sshUsername": "",
                "sshAuthMethod": "password",
                "sshPrivateKeyPath": "",
                "sortOrder": index,
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("connections.json"), options: .atomic)
    }

    /// `screencapture -l` needs the window's own number, which only the window server knows.
    /// Largest wins, because a sheet, a popover and the main window all report layer 0.
    private func mainWindowNumber() -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates = entries.compactMap { entry -> (number: CGWindowID, area: CGFloat)? in
            guard entry[kCGWindowOwnerName as String] as? String == "TablePro",
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds)
            else {
                return nil
            }
            return (number, bounds.width * bounds.height)
        }

        return candidates.max { $0.area < $1.area }?.number
    }

    /// The site paints the window shadow in CSS and needs the file to carry the rounded corners as
    /// transparency. A capture taken any other way, `XCUIScreen.screenshot()` above all, comes back
    /// opaque and square: right on its own, wrong on the page, a square plate inside a soft shadow.
    /// These four checks are what catch that before the file reaches the repository.
    private func assertShippable(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "The captured file is not an image")

        XCTAssertEqual(
            bitmap.pixelsWide, Self.pixelWidth,
            "Captures have to come off a 2x display. This one is \(bitmap.pixelsWide) pixels wide."
        )
        XCTAssertEqual(bitmap.pixelsHigh, Self.pixelHeight)
        XCTAssertTrue(bitmap.hasAlpha, "No alpha channel, so the window corners are square")

        let corner = bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1
        XCTAssertEqual(Double(corner), 0, accuracy: 0.01, "The top left corner is not transparent")
    }

    private func attach(_ url: URL, named name: String) {
        guard let attachment = try? XCTAttachment(contentsOfFile: url) else { return }
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Duplicated from `ScreenshotEnvironment`, which lives in the app and cannot be imported here.
/// The app-side test in `TableProTests` asserts the two agree.
internal enum ScreenshotEnvironmentNames {
    internal static let frame = "TABLEPRO_SCREENSHOT_FRAME"
    internal static let appearance = "TABLEPRO_SCREENSHOT_APPEARANCE"
}
