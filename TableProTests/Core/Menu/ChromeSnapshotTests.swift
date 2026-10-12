//
//  ChromeSnapshotTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

// Re-record ChromeSnapshot.json after an intended change to the menu bar, the main window toolbar
// or the Settings panes:
// TEST_RUNNER_TABLEPRO_RECORD_CHROME_SNAPSHOT=1 .claude/skills/fix-issue/scripts/verify.sh test ChromeSnapshotTests
@MainActor
struct ChromeSnapshotTests {
    @Test(
        "Menu bar, toolbar sets and Settings panes match ChromeSnapshot.json",
        .enabled(if: ChromeSnapshot.matchesTheRecordingMachine)
    )
    func chromeMatchesTheRecordedSnapshot() throws {
        let actual = ChromeSnapshot.render()
        #expect((try? JSONSerialization.jsonObject(with: Data(actual.utf8))) != nil, "The snapshot is not valid JSON")

        if ProcessInfo.processInfo.environment["TABLEPRO_RECORD_CHROME_SNAPSHOT"] == "1" {
            try actual.write(to: ChromeSnapshot.goldenURL, atomically: true, encoding: .utf8)
            return
        }

        let expected = try String(contentsOf: ChromeSnapshot.goldenURL, encoding: .utf8)
        guard actual != expected else { return }
        let actualURL = FileManager.default.temporaryDirectory.appendingPathComponent("ChromeSnapshot.actual.json")
        try? actual.write(to: actualURL, atomically: true, encoding: .utf8)
        Issue.record(
            """
            The chrome changed. If that is intended, re-record with the command at the top of \
            ChromeSnapshotTests.swift. Full snapshot: \(actualURL.path)
            \(ChromeSnapshot.lineDiff(from: expected, to: actual))
            """
        )
    }

    @Test("Taking the snapshot leaves the app's own menus in place")
    func snapshotLeavesTheAppMenusAlone() {
        let app = NSApplication.shared
        let before = [app.mainMenu, app.servicesMenu, app.windowsMenu, app.helpMenu]
        _ = ChromeSnapshot.render()
        let after = [app.mainMenu, app.servicesMenu, app.windowsMenu, app.helpMenu]
        #expect(zip(before, after).allSatisfy { $0 === $1 })
    }
}

@MainActor
private enum ChromeSnapshot {
    static let goldenURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("ChromeSnapshot.json")

    // The golden is recorded in English, on a US key layout, on macOS 14 or later: titles are
    // localized, default key equivalents follow the active layout, and macOS 13 builds a different
    // toolbar.
    nonisolated static var matchesTheRecordingMachine: Bool {
        let macOS14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        guard Bundle.main.preferredLocalizations.first == "en",
              ProcessInfo.processInfo.isOperatingSystemAtLeast(macOS14) else { return false }
        return (UInt16(0)...127).allSatisfy { code in
            guard let usCharacter = KeyCode(rawValue: code)?.usBaseCharacter else { return true }
            return KeyboardLayout.baseCharacter(for: code) == usCharacter
        }
    }

    static func render() -> String {
        let menuLines = menuBarEntries().map { "    \($0)" }.joined(separator: ",\n")
        let panes = SettingsPaneTabViewController.paneOrder
            .map { "    {\"id\": \(quoted($0.rawValue)), \"title\": \(quoted($0.title))}" }
            .joined(separator: ",\n")
        return """
        {
          "menuBar": [
        \(menuLines)
          ],
          "mainWindowToolbar": {
            "default": [
        \(identifierLines(MainWindowToolbar.defaultItemIdentifiers))
            ],
            "allowed": [
        \(identifierLines(MainWindowToolbar.allowedItemIdentifiers))
            ]
          },
          "settingsPanes": [
        \(panes)
          ]
        }

        """
    }

    // MainMenuBuilder.build assigns NSApp's Services, Window and Help menus. The app's own are put
    // back so the test host keeps the menu bar it launched with.
    private static func menuBarEntries() -> [String] {
        let app = NSApplication.shared
        let services = app.servicesMenu
        let windows = app.windowsMenu
        let help = app.helpMenu
        defer {
            app.servicesMenu = services
            app.windowsMenu = windows
            app.helpMenu = help
        }
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        return entries(in: menu, path: [], appKitOwned: app.servicesMenu)
    }

    // AppKit fills the Services menu and appends open windows to the Window menu, so neither is
    // the app's chrome.
    private static func entries(in menu: NSMenu, path: [String], appKitOwned: NSMenu?) -> [String] {
        menu.items.flatMap { item -> [String] in
            if item.target is NSWindow { return [] }
            guard !item.isSeparatorItem else {
                return ["{\"path\": \(quoted(path.joined(separator: " > "))), \"separator\": true}"]
            }
            let itemPath = path + [item.title]
            let line = entry(for: item, path: itemPath.joined(separator: " > "))
            guard let submenu = item.submenu, submenu !== appKitOwned else { return [line] }
            return [line] + entries(in: submenu, path: itemPath, appKitOwned: appKitOwned)
        }
    }

    // AppKit names an item without an identifier after its action, and points a submenu's item at
    // submenuAction:. Neither is authored, so neither is recorded.
    private static func entry(for item: NSMenuItem, path: String) -> String {
        var fields = ["\"path\": \(quoted(path))"]
        let action = item.action.flatMap { $0 == #selector(NSMenu.submenuAction(_:)) ? nil : NSStringFromSelector($0) }
        if let identifier = item.identifier?.rawValue, identifier != item.action.map(NSStringFromSelector) {
            fields.append("\"identifier\": \(quoted(identifier))")
        }
        if let action {
            fields.append("\"action\": \(quoted(action))")
        }
        if !item.keyEquivalent.isEmpty {
            fields.append("\"key\": \(quoted(keyName(item.keyEquivalent)))")
            let modifiers = modifierNames(item.keyEquivalentModifierMask).map(quoted).joined(separator: ", ")
            fields.append("\"modifiers\": [\(modifiers)]")
        }
        if item.isAlternate {
            fields.append("\"alternate\": true")
        }
        if item.isHidden {
            fields.append("\"hidden\": true")
        }
        return "{\(fields.joined(separator: ", "))}"
    }

    private static let specialKeys: [UInt32: String] = [
        0x08: "backspace", 0x09: "tab", 0x0D: "return", 0x19: "backtab", 0x1B: "escape", 0x20: "space",
        0x7F: "delete", 0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right",
        0xF728: "forward delete", 0xF729: "home", 0xF72B: "end", 0xF72C: "page up", 0xF72D: "page down",
    ]

    private static func keyName(_ key: String) -> String {
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return key }
        if let name = specialKeys[scalar.value] { return name }
        if (0xF704...0xF726).contains(scalar.value) { return "F\(scalar.value - 0xF703)" }
        if scalar.properties.generalCategory == .privateUse || scalar.value < 0x20 {
            return String(format: "U+%04X", scalar.value)
        }
        return key
    }

    private static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        let names: [(NSEvent.ModifierFlags, String)] = [
            (.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command"), (.function, "function"),
        ]
        return names.filter { flags.contains($0.0) }.map(\.1)
    }

    private static func identifierLines(_ identifiers: [NSToolbarItem.Identifier]) -> String {
        identifiers.map { "      \(quoted($0.rawValue))" }.joined(separator: ",\n")
    }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(text), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }

    static func lineDiff(from expected: String, to actual: String) -> String {
        let old = expected.components(separatedBy: "\n")
        let new = actual.components(separatedBy: "\n")
        let changes = new.difference(from: old).map { change -> String in
            switch change {
            case let .remove(_, line, _): "- \(line)"
            case let .insert(_, line, _): "+ \(line)"
            }
        }
        let shown = changes.prefix(80).joined(separator: "\n")
        return changes.count > 80 ? "\(shown)\n… \(changes.count - 80) more" : shown
    }
}
