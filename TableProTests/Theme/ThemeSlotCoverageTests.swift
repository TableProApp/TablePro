//
//  ThemeSlotCoverageTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

struct ThemeSlotCoverageTests {
    @Test("Slot paths are unique and sit under their group's key")
    func slotPathsAreWellFormed() {
        let paths = ThemeSlot.allCases.map(\.rawValue)
        #expect(Set(paths).count == paths.count)

        for slot in ThemeSlot.allCases {
            switch slot.group {
            case .window:
                #expect(slot.rawValue.hasPrefix("window."), "\(slot.rawValue)")
            case .editor:
                #expect(slot.rawValue.hasPrefix("editor."), "\(slot.rawValue)")
                #expect(!slot.rawValue.hasPrefix("editor.syntax."), "\(slot.rawValue)")
            case .syntax:
                #expect(slot.rawValue.hasPrefix("editor.syntax."), "\(slot.rawValue)")
            case .dataGrid:
                #expect(slot.rawValue.hasPrefix("dataGrid."), "\(slot.rawValue)")
            }
        }
    }

    @Test("Every slot belongs to exactly one group")
    func groupsPartitionTheSlots() {
        let grouped = ThemeSlotGroup.allCases.flatMap(\.slots)
        #expect(Set(grouped) == Set(ThemeSlot.allCases))
        #expect(grouped.count == ThemeSlot.allCases.count)
    }

    /// The theme editor lists one section per group in this order, so the window leads the sheet.
    @Test("The window group comes first and holds only the window background")
    func windowGroupLeads() {
        #expect(ThemeSlotGroup.allCases.first == .window)
        #expect(ThemeSlotGroup.window.slots == [.windowBackdrop])
        #expect(ThemeSlot.windowBackdrop.rawValue == "window.background")
        #expect(ThemeSlot.windowBackdrop.nativeColor === NSColor.windowBackgroundColor)
        #expect(ThemeSlot.allCases.filter(\.yieldsToIncreasedContrast) == [.windowBackdrop])
    }

    // MARK: - Bundled themes

    /// The bundle is the list, so a third bundled theme is decoded here the day it ships.
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
            let document = try ThemeDocument(data: try Data(contentsOf: file))
            #expect(document.id == file.deletingPathExtension().lastPathComponent)
            #expect(document.id.hasPrefix(ThemeDefinition.builtInPrefix))
            #expect(!document.colors.isEmpty, "\(document.id) overrides nothing")
            ids.insert(document.id)
        }

        #expect(ids.isSuperset(of: ["tablepro.dracula", "tablepro.nord"]))
    }

    // MARK: - Default Light and Default Dark

    private static let syntaxWithoutOperator = Set(ThemeSlotGroup.syntax.slots).subtracting([.syntaxOperator])

    /// Xcode 27.1 `Default (Light).xccolortheme`: keyword, string, number, comment, system function
    /// and system type. SQL `NULL` takes the keyword colour the way Swift's `nil` does.
    @Test("Default Light overrides only syntax, with Xcode's Default (Light) values")
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
        let actual = BuiltInThemes.light.overrides.mapValues { $0.hex }

        #expect(Set(actual.keys) == Self.syntaxWithoutOperator)
        #expect(actual == expected)
        #expect(BuiltInThemes.light.appearance == .light)
        #expect(BuiltInThemes.light.id == BuiltInThemes.defaultLightId)
    }

    @Test("Default Dark overrides only syntax, with Xcode's Default (Dark) values")
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
        let actual = BuiltInThemes.dark.overrides.mapValues { $0.hex }

        #expect(Set(actual.keys) == Self.syntaxWithoutOperator)
        #expect(actual == expected)
        #expect(BuiltInThemes.dark.appearance == .dark)
        #expect(BuiltInThemes.default(for: .dark).id == BuiltInThemes.defaultDarkId)
    }
}
