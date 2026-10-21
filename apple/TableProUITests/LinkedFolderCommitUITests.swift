import XCTest

final class LinkedFolderCommitUITests: UITestCase {
    private static let folderName = "team-queries"

    func testCommittingAndPushingALinkedFolderFromTheSidebar() throws {
        let repository = try GitFixtureRepository(folderName: Self.folderName)
        defer { repository.remove() }
        try repository.write("SELECT 2;\n", to: "report.sql")

        let launch = try launchWithFixture(arguments: repository.linkedFolderArguments)
        let app = launch.app
        let window = launch.window
        menuItem("Show Favorites", under: "View", in: app).click()

        let folderRow = window.outlines.staticTexts[Self.folderName].firstMatch
        XCTAssertTrue(waitUntilHittable(folderRow, timeout: 30), "The linked folder must be listed in Favorites")
        XCTAssertTrue(
            openContextMenuItem("Commit…", on: folderRow, in: app),
            "A linked folder with a changed file offers Commit… once its status has loaded"
        )

        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitToExist(timeout: 15), "Commit… opens the commit sheet")
        let message = sheet.textViews.firstMatch
        XCTAssertTrue(waitUntilHittable(message, timeout: 15), "The sheet takes a commit message")
        message.click()
        message.typeText("Update the report")
        let commit = sheet.buttons["Commit"].firstMatch
        XCTAssertTrue(waitForPredicate(timeout: 10) { commit.isEnabled }, "A checked file and a message enable Commit")
        commit.click()

        XCTAssertTrue(waitForPredicate(timeout: 60) { !sheet.exists }, "A commit that succeeds closes the sheet")
        XCTAssertEqual(try repository.output("log", "-1", "--format=%s"), "Update the report")
        XCTAssertEqual(try repository.output("status", "--porcelain"), "", "The checked file is committed")

        XCTAssertTrue(openContextMenuItem("Push", on: folderRow, in: app), "A linked folder in a repository offers Push")
        XCTAssertTrue(
            waitForPredicate(timeout: 60) { (try? repository.remoteOutput("log", "-1", "--format=%s", "main")) == "Update the report" },
            "Push must land the commit on the remote branch"
        )
    }

    // The Git commands join the menu once the folder's status loads, so an early menu is closed and reopened.
    private func openContextMenuItem(_ title: String, on row: XCUIElement, in app: XCUIApplication) -> Bool {
        waitForPredicate(timeout: 30) {
            row.rightClick()
            let item = self.contextMenuItem(title, in: app)
            guard item.waitToExist(timeout: 2), item.isHittable else {
                app.typeKey(.escape, modifierFlags: [])
                return false
            }
            item.click()
            return true
        }
    }
}

// A clone of a bare remote, both under the runner's temporary folder, with one committed and pushed query.
struct GitFixtureRepository {
    let root: URL
    let clone: URL
    let folder: URL

    init(folderName: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-git-uitest-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        clone = root.appendingPathComponent("clone")
        folder = clone.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.git(["init", "-q", "--bare", "-b", "main", root.appendingPathComponent("remote.git").path], in: root)
        try Self.git(["init", "-q", "-b", "main"], in: clone)
        for (key, value) in [
            ("user.name", "Ann Author"), ("user.email", "ann@example.com"),
            ("commit.gpgsign", "false"), ("core.hooksPath", ".git/hooks"),
        ] {
            try Self.git(["config", key, value], in: clone)
        }
        try write("SELECT 1;\n", to: "report.sql")
        try Self.git(["add", "-A"], in: clone)
        try Self.git(["commit", "-qm", "Add the report"], in: clone)
        try Self.git(["remote", "add", "origin", root.appendingPathComponent("remote.git").path], in: clone)
        try Self.git(["push", "-q", "-u", "origin", "main"], in: clone)
    }

    var linkedFolderArguments: [String] {
        let folders = #"[{"id":"\#(UUID().uuidString)","path":"\#(folder.path)","isEnabled":true}]"#
        let hex = Data(folders.utf8).map { String(format: "%02x", $0) }.joined()
        return ["-com.TablePro.linkedSQLFolders", "<\(hex)>"]
    }

    func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    func output(_ arguments: String...) throws -> String {
        try Self.git(arguments, in: clone)
    }

    func remoteOutput(_ arguments: String...) throws -> String {
        try Self.git(["--git-dir=\(root.appendingPathComponent("remote.git").path)"] + arguments, in: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    // The runner is sandboxed, and the `/usr/bin/git` shim's xcrun refuses to run inside a sandbox.
    private static let executable: URL? = {
        var candidates: [String] = []
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            candidates.append(developer + "/usr/bin/git")
        }
        if let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(developer + "/usr/bin/git")
        }
        let applications = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        candidates += applications.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted()
            .map { "/Applications/\($0)/Contents/Developer/usr/bin/git" }
        candidates.append("/Library/Developer/CommandLineTools/usr/bin/git")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }()

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = try XCTUnwrap(executable, "No git outside the xcrun shim")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // The fixture ignores the developer's own Git config, signing and hooks included.
        process.environment = [
            "HOME": directory.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/bin",
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: message, as: UTF8.self)
            throw NSError(domain: "GitFixtureRepository", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) exited \(process.terminationStatus): \(detail)",
            ])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
