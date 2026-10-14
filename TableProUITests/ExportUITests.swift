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
            (nameField.value as? String)?.hasPrefix("album-export") == true,
            "Moving folder must keep the typed name, the field holds '\(nameField.value as? String ?? "nil")'"
        )
        panel.buttons["OKButton"].firstMatch.click()

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
}
