//
//  ObjectKindsToolbarIconStyleTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

extension GlobalStateSuites {
    /// The Objects buttons under Settings > Appearance > Object Icons. The standard style is the run as it was drawn
    /// before the setting existed; the colorful one draws each kind the way the sidebar does.
    @Suite(.appSettings { $0.appearance.objectIconStyle = .standard })
    @MainActor
    struct ObjectKindsToolbarIconStyleTests {
        private typealias Drawn = (identifier: NSToolbarItem.Identifier, symbolName: String, tint: NSColor)

        private static let standardRun: [Drawn] = [
            (MainWindowToolbar.objectTables, "tablecells", .systemBlue),
            (MainWindowToolbar.objectViews, "eye", .systemTeal),
            (MainWindowToolbar.objectFunctions, "function", .systemPurple),
            (MainWindowToolbar.objectUsers, "person.2", .systemOrange),
            (MainWindowToolbar.objectQuery, "doc.text", .systemGreen),
            (MainWindowToolbar.objectBackup, "archivebox", .systemBrown),
        ]

        private static let colorfulRun: [Drawn] = [
            (MainWindowToolbar.objectTables, "tablecells.fill", .systemBlue),
            (MainWindowToolbar.objectViews, "eyeglasses", .systemCyan),
            (MainWindowToolbar.objectFunctions, "function", .systemPurple),
            (MainWindowToolbar.objectUsers, "person.fill", .systemBrown),
            (MainWindowToolbar.objectQuery, "doc.text.fill", .systemOrange),
            (MainWindowToolbar.objectBackup, "archivebox", .systemBrown),
        ]

        private static func button(_ identifier: NSToolbarItem.Identifier) throws -> ObjectKindButton {
            try #require(MainWindowToolbar.objectKindButtons.first { $0.identifier == identifier })
        }

        private static func expectRun(_ run: [Drawn], style: ObjectIconStyle) throws {
            #expect(run.map { $0.identifier } == MainWindowToolbar.objectKindItemIdentifiers)
            for drawn in run {
                let icon = MainWindowToolbar.objectKindIcon(try button(drawn.identifier), style: style)
                let name = drawn.identifier.rawValue
                #expect(icon.symbolName == drawn.symbolName, "\(name)")
                #expect(icon.tint == drawn.tint, "\(name)")
                #expect(MainWindowToolbar.objectKindTint(for: drawn.identifier, style: style) == drawn.tint, "\(name)")
            }
        }

        @Test("The standard style draws each button's glyph and hue from before the style existed")
        func standardStyleKeepsTheRun() throws {
            try Self.expectRun(Self.standardRun, style: .standard)
            for drawn in Self.standardRun {
                #expect(MainWindowToolbar.objectKindTint(for: drawn.identifier) == drawn.tint, "The setting starts standard")
            }
        }

        @Test("The colorful style draws each kind as the sidebar does, and Backup, which opens no kind, as it was")
        func colorfulStyleDrawsTheKinds() throws {
            try Self.expectRun(Self.colorfulRun, style: .colorful)
            let tables = try Self.button(MainWindowToolbar.objectTables)
            let sidebar = ObjectIconProvider.icon(for: .relation(.table), style: .colorful)
            #expect(MainWindowToolbar.objectKindIcon(tables, style: .colorful).symbolName == sidebar.symbolName)
        }

        @Test("Every glyph either style draws is a symbol the system has")
        func everyGlyphExists() {
            for button in MainWindowToolbar.objectKindButtons {
                for style in ObjectIconStyle.allCases {
                    let glyph = MainWindowToolbar.objectKindGlyph(button, style: style)
                    #expect(glyph.image() != nil, "\(button.identifier.rawValue) in \(style.rawValue)")
                }
            }
        }

        @Test(
            "An open window's buttons take the new style the moment the setting changes",
            .appSettings { $0.general.showsObjectToolbar = false }
        )
        func settingReachesAnOpenWindow() throws {
            let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_512, height: 861))
            defer { fixture.tearDown() }
            let storage = try EphemeralDefaults()
            fixture.toolbarOwner.objectKindsRecord = ToolbarObjectKindsRecord(defaults: storage.defaults)
            AppSettingsManager.shared.general.showsObjectToolbar = true
            let toolbar = try #require(fixture.window.toolbar)
            let objectKinds = Set(MainWindowToolbar.objectKindItemIdentifiers)
            let keys = {
                Dictionary(uniqueKeysWithValues: toolbar.items.filter { objectKinds.contains($0.itemIdentifier) }.map {
                    ($0.itemIdentifier, ($0 as? StatefulToolbarItem)?.appliedGlyphKey)
                })
            }
            #expect(keys().count == objectKinds.count)
            #expect(keys()[MainWindowToolbar.objectTables] == "standard/tablecells")

            AppSettingsManager.shared.appearance.objectIconStyle = .colorful
            #expect(keys()[MainWindowToolbar.objectTables] == "colorful/tablecells.fill")
            #expect(keys()[MainWindowToolbar.objectViews] == "colorful/eyeglasses")
            #expect(keys()[MainWindowToolbar.objectBackup] == "colorful/archivebox")

            AppSettingsManager.shared.appearance.objectIconStyle = .standard
            #expect(keys()[MainWindowToolbar.objectTables] == "standard/tablecells")
            #expect(keys()[MainWindowToolbar.objectViews] == "standard/eye")
        }
    }
}
