import XCTest

final class ExportUITests: UITestCase {
    func testExportingATableWritesACSVFile() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app
        let destination = try XCTUnwrap(sandboxRoot)
        let exported = destination.appendingPathComponent("album-export.csv")

        // The object browser's selection is what the export preselects.
        _ = openFromObjectBrowser("album", in: launch)
        app.typeShortcut(.export)

        let sheet = window.children(matching: .sheet).firstMatch
        XCTAssertTrue(
            sheet.staticTexts["1 table to export"].waitToExist(timeout: 30),
            "Export Tables must open with the selected table, album, chosen"
        )
        let format = element(sheet.popUpButtons, labelEndingWith: "Format")
        XCTAssertTrue(format.waitToExist(timeout: 10), "The export sheet must offer a format menu")
        if (format.value as? String) != "CSV" {
            format.click()
            let csv = app.menuItems["CSV"].firstMatch
            XCTAssertTrue(csv.waitToExist(timeout: 10), "CSV must be an export format")
            csv.click()
        }
        XCTAssertTrue(waitForPredicate(timeout: 10) { (format.value as? String) == "CSV" }, "The format must be CSV")

        save(from: sheet, to: exported, in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { FileManager.default.fileExists(atPath: exported.path) },
            "Export must write \(exported.lastPathComponent) into the chosen folder"
        )
        let lines = try String(contentsOf: exported, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            lines,
            ["id,title,artist_id", "1,North,1", "2,South,2", "3,East,2", "4,West,3", "5,Up,4", "6,Down,5"],
            "The file must hold album's header and every row"
        )
    }

    func testExportingADataDictionaryWritesMarkdown() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app
        let destination = try XCTUnwrap(sandboxRoot)
        let exported = destination.appendingPathComponent("album-dictionary.md")

        _ = openFromObjectBrowser("album", in: launch)
        menuItem("Export Data Dictionary…", under: "File", in: app).click()

        let sheet = window.children(matching: .sheet).firstMatch
        XCTAssertTrue(
            sheet.staticTexts["1 table to export"].waitToExist(timeout: 30),
            "Export Data Dictionary must open with the selected table, album, chosen"
        )
        let format = element(sheet.popUpButtons, labelEndingWith: "Format")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { (format.value as? String) == "Data Dictionary" },
            "The sheet must open on the Data Dictionary format"
        )
        save(from: sheet, to: exported, in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { FileManager.default.fileExists(atPath: exported.path) },
            "Export must write \(exported.lastPathComponent) into the chosen folder"
        )
        let markdown = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("# album-dictionary\n"), "The file must be titled after its name")
        XCTAssertTrue(markdown.contains("- [`album`](#album)"), "The contents must link to album")
        XCTAssertTrue(markdown.contains("## `album`"), "album must have its own section")
        XCTAssertTrue(markdown.contains("| `title` | `TEXT` | No |"), "Each column must list its type and nullability")
        XCTAssertFalse(markdown.contains("North"), "A data dictionary must hold no row")
    }

    func testExportingEveryTableAsStructureOnly() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let app = launch.app
        let destination = try XCTUnwrap(sandboxRoot)
        let exported = destination.appendingPathComponent("schema.sql")

        _ = openFromObjectBrowser("album", in: launch)
        app.typeShortcut(.export)

        let sheet = window.children(matching: .sheet).firstMatch
        XCTAssertTrue(sheet.staticTexts["1 table to export"].waitToExist(timeout: 30), "Export must open")
        let format = element(sheet.popUpButtons, labelEndingWith: "Format")
        XCTAssertTrue(format.waitToExist(timeout: 10), "The export sheet must offer a format menu")
        if (format.value as? String) != "SQL" {
            format.click()
            let sql = app.menuItems["SQL"].firstMatch
            XCTAssertTrue(sql.waitToExist(timeout: 10), "SQL must be an export format")
            sql.click()
        }
        XCTAssertTrue(waitForPredicate(timeout: 10) { (format.value as? String) == "SQL" }, "The format must be SQL")

        let tree = sheet.outlines.firstMatch
        XCTAssertTrue(tree.waitToExist(timeout: 10), "The export tree must show")
        // The fixture's database row is named after its file's path.
        let database = tree.checkBoxes.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "/", ".sqlite")
        ).firstMatch
        XCTAssertTrue(database.waitToExist(timeout: 10), "The database row must offer its own checkbox")
        database.click()
        XCTAssertTrue(
            sheet.staticTexts["6 tables to export"].waitToExist(timeout: 10),
            "Ticking the database must select every table"
        )
        for column in ["Drop", "Data"] {
            let box = tree.checkBoxes.matching(
                NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "\(column) for ", ".sqlite")
            ).firstMatch
            XCTAssertTrue(box.waitToExist(timeout: 10), "The database row must offer a \(column) checkbox")
            box.click()
            XCTAssertTrue(
                waitForPredicate(timeout: 10) { (box.value as? Int) == 0 },
                "\(column) must turn off for the whole database"
            )
        }

        save(from: sheet, to: exported, in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { FileManager.default.fileExists(atPath: exported.path) },
            "Export must write \(exported.lastPathComponent) into the chosen folder"
        )
        let sql = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertEqual(
            sql.components(separatedBy: "CREATE TABLE").count - 1, 6,
            "The file must create every one of the fixture's six tables"
        )
        XCTAssertFalse(sql.contains("INSERT INTO"), "A structure-only export must hold no row")
        XCTAssertFalse(sql.contains("DROP TABLE"), "A structure-only export must drop nothing")
    }

    // Clicks Export…, names the file in the save panel, moves the panel to the file's folder and saves.
    private func save(from sheet: XCUIElement, to exported: URL, in app: XCUIApplication) {
        let destination = exported.deletingLastPathComponent()
        let export = sheet.buttons["Export…"].firstMatch
        XCTAssertTrue(waitForPredicate(timeout: 15) { export.exists && export.isEnabled }, "Export must be offered")
        export.click()

        let panel = sheet.descendants(matching: .sheet).matching(identifier: "save-panel").firstMatch
        let nameField = panel.textFields["saveAsNameTextField"].firstMatch
        XCTAssertTrue(panel.waitToExist(timeout: 30), "Export must ask where to save")
        // The panel takes keys only once it is key, and the name field takes the keyboard in that moment.
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { self.holdsKeyboardFocus(nameField) },
            "The save panel must become key with the keyboard in its name field"
        )
        panel.typeKey("a", modifierFlags: .command)
        panel.typeText(exported.lastPathComponent)

        panel.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !self.holdsKeyboardFocus(nameField) },
            "Go to Folder must take the keyboard"
        )
        app.typeText(destination.path)
        app.typeKey(.return, modifierFlags: [])
        let folder = panel.popUpButtons.matching(NSPredicate(format: "value == %@", destination.lastPathComponent))
        XCTAssertTrue(
            folder.firstMatch.waitToExist(timeout: 15),
            "The panel must move to the sandbox folder"
        )
        // With the extension hidden, the field shows the name without it.
        XCTAssertTrue(
            (nameField.value as? String)?.hasPrefix(exported.deletingPathExtension().lastPathComponent) == true,
            "Moving folder must keep the typed name, the field holds '\(nameField.value as? String ?? "nil")'"
        )
        panel.buttons["OKButton"].firstMatch.click()
    }
}
