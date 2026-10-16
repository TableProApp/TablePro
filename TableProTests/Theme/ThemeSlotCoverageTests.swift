//
//  ThemeSlotCoverageTests.swift
//  TableProTests
//
//  What needs the app: the bundled theme files and the AppKit colors the defaults draw. The slot
//  registry itself is tested in TableProThemeTests.
//

import AppKit
import Foundation
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct ThemeSlotCoverageTests {
    @Test("The window slot draws the window's own background color natively")
    func windowSlotIsTheWindowColor() {
        #expect(ThemeSlot.windowBackdrop.nativeColor === NSColor.windowBackgroundColor)
    }

    // MARK: - Bundled themes

    /// The bundle is the list, so a new bundled theme is decoded here the day it ships.
    private static func bundledThemeFiles() -> [URL] {
        (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(ThemeDefinition.builtInPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test("Every bundled theme decodes, and its id is its file name")
    func bundledThemesDecode() throws {
        let files = Self.bundledThemeFiles()
        var ids: Set<String> = []

        for file in files {
            let theme = try ThemeFileFormat.decode(try Data(contentsOf: file))
            #expect(theme.id == file.deletingPathExtension().lastPathComponent)
            #expect(theme.id.hasPrefix(ThemeDefinition.builtInPrefix))
            #expect(!theme.overrides.isEmpty, "\(theme.id) sets nothing")
            ids.insert(theme.id)
        }

        #expect(ids.isSuperset(of: ["tablepro.dracula", "tablepro.nord"]))
    }

    // MARK: - Default Light and Default Dark

    private static let syntaxWithoutOperator = Set(ThemeSlotGroup.syntax.slots).subtracting([.syntaxOperator])

    private static func drawnSyntax(_ theme: ThemeDefinition, in name: NSAppearance.Name) -> [ThemeSlot: String] {
        var drawn: [ThemeSlot: String] = [:]
        for slot in syntaxWithoutOperator {
            drawn[slot] = ThemeTestFixture.hex(theme.color(for: slot), in: name)
        }
        return drawn
    }

    /// Xcode 27.1 `Default (Light).xccolortheme`: keyword, string, number, comment, system function
    /// and system type. SQL `NULL` takes the keyword colour the way Swift's `nil` does.
    @Test("Default Light sets nothing and draws Xcode's Default (Light) syntax")
    func defaultLightIsXcodeDefaultLight() {
        let expected: [ThemeSlot: String] = [
            .syntaxKeyword: "#9B2393",
            .syntaxString: "#C41A16",
            .syntaxNumber: "#1C00CF",
            .syntaxComment: "#5D6C79",
            .syntaxFunction: "#6C36A9",
            .syntaxType: "#3900A0",
            .syntaxNull: "#9B2393",
        ]

        #expect(BuiltInThemes.light.overrides.isEmpty)
        #expect(Self.drawnSyntax(BuiltInThemes.light, in: .aqua) == expected)
        #expect(BuiltInThemes.light.appearance == .light)
        #expect(BuiltInThemes.light.id == BuiltInThemes.defaultLightId)
    }

    @Test("Default Dark sets nothing and draws Xcode's Default (Dark) syntax")
    func defaultDarkIsXcodeDefaultDark() {
        let expected: [ThemeSlot: String] = [
            .syntaxKeyword: "#FC5FA3",
            .syntaxString: "#FC6A5D",
            .syntaxNumber: "#D0BF69",
            .syntaxComment: "#6C7986",
            .syntaxFunction: "#A167E6",
            .syntaxType: "#D0A8FF",
            .syntaxNull: "#FC5FA3",
        ]

        #expect(BuiltInThemes.dark.overrides.isEmpty)
        #expect(Self.drawnSyntax(BuiltInThemes.dark, in: .darkAqua) == expected)
        #expect(BuiltInThemes.dark.appearance == .dark)
        #expect(BuiltInThemes.default(for: .dark).id == BuiltInThemes.defaultDarkId)
    }

    /// The default ids used to keep their syntax as overrides, which a duplicate copied and then
    /// froze under Increase Contrast. A copy now draws the same adaptive objects as the default.
    @Test("A duplicate of a default draws the default's adaptive syntax objects")
    func duplicateOfADefaultStaysAdaptive() {
        var copy = BuiltInThemes.dark
        copy.id = "user.copy"
        for slot in Self.syntaxWithoutOperator {
            #expect(copy.color(for: slot) === BuiltInThemes.dark.color(for: slot), "\(slot.rawValue)")
            #expect(copy.color(for: slot) === BuiltInThemes.adaptiveSyntaxColor(slot, appearance: .dark), "\(slot.rawValue)")
        }
    }
}
