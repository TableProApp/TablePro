//
//  ThemeDefinitionTests.swift
//  TableProTests
//
//  Tests for ThemeDefinition and EditorThemeColors, focusing on the
//  currentStatementHighlight field and Codable backward compatibility.
//

import AppKit
import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Theme Definition")
struct ThemeDefinitionTests {
    // MARK: - Default light theme

    @Test("Default light editor colors include currentStatementHighlight")
    func defaultLightHasCurrentStatementHighlight() {
        let colors = EditorThemeColors.defaultLight
        #expect(colors.currentStatementHighlight == "#F0F4FA")
    }

    @Test("Default light editor colors have expected background")
    func defaultLightBackground() {
        let colors = EditorThemeColors.defaultLight
        #expect(colors.background == "#FFFFFF")
    }

    // MARK: - Codable round-trip

    @Test("EditorThemeColors survives encode-decode round-trip")
    func editorThemeColorsRoundTrip() throws {
        let original = EditorThemeColors.defaultLight
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(EditorThemeColors.self, from: data)

        #expect(decoded.currentStatementHighlight == original.currentStatementHighlight)
        #expect(decoded.background == original.background)
        #expect(decoded.text == original.text)
        #expect(decoded.cursor == original.cursor)
        #expect(decoded.currentLineHighlight == original.currentLineHighlight)
        #expect(decoded.selection == original.selection)
        #expect(decoded.lineNumber == original.lineNumber)
        #expect(decoded.invisibles == original.invisibles)
        #expect(decoded == original)
    }

    @Test("Full ThemeDefinition survives encode-decode round-trip")
    func themeDefinitionRoundTrip() throws {
        let original = ThemeDefinition.default
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ThemeDefinition.self, from: data)

        #expect(decoded.editor.currentStatementHighlight == original.editor.currentStatementHighlight)
        #expect(decoded == original)
    }

    // MARK: - Backward compatibility

    @Test("Decoding JSON missing currentStatementHighlight falls back to default")
    func backwardCompatibilityMissingField() throws {
        // JSON with all editor fields EXCEPT currentStatementHighlight
        let json = """
        {
            "background": "#1E1E1E",
            "text": "#D4D4D4",
            "cursor": "#AEAFAD",
            "currentLineHighlight": "#2A2D2E",
            "selection": "#264F78",
            "lineNumber": "#858585",
            "invisibles": "#3B3B3B",
            "syntax": {
                "keyword": "#569CD6",
                "string": "#CE9178",
                "number": "#B5CEA8",
                "comment": "#6A9955",
                "null": "#569CD6",
                "operator": "#D4D4D4",
                "function": "#DCDCAA",
                "type": "#4EC9B0"
            }
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(EditorThemeColors.self, from: data)

        // Should fall back to defaultLight's value
        #expect(decoded.currentStatementHighlight == EditorThemeColors.defaultLight.currentStatementHighlight)
        // Other fields should use the provided values
        #expect(decoded.background == "#1E1E1E")
        #expect(decoded.text == "#D4D4D4")
    }

    @Test("Decoding empty JSON falls back to all defaults")
    func emptyJsonFallsBackToDefaults() throws {
        let json = "{}"
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(EditorThemeColors.self, from: data)

        #expect(decoded == EditorThemeColors.defaultLight)
    }

    @Test("Decoding JSON with currentStatementHighlight preserves custom value")
    func customCurrentStatementHighlight() throws {
        let json = """
        {
            "background": "#FFFFFF",
            "text": "#000000",
            "cursor": "#000000",
            "currentLineHighlight": "#ECF5FF",
            "selection": "#B4D8FD",
            "lineNumber": "#747478",
            "invisibles": "#D6D6D6",
            "currentStatementHighlight": "#AABBCC",
            "syntax": {
                "keyword": "#9B2393",
                "string": "#C41A16",
                "number": "#1C00CF",
                "comment": "#5D6C79",
                "null": "#9B2393",
                "operator": "#000000",
                "function": "#326D74",
                "type": "#3F6E74"
            }
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(EditorThemeColors.self, from: data)

        #expect(decoded.currentStatementHighlight == "#AABBCC")
    }

    // MARK: - Editor font resolver

    @Test("Font resolver always exposes System Mono")
    func resolverExposesSystemMono() {
        let families = EditorFontResolver.availableMonospacedFamilies
        #expect(families.contains { $0.id == EditorFontResolver.systemMonoId })
    }

    @Test("System Mono is first in picker list")
    func systemMonoFirst() {
        let families = EditorFontResolver.availableMonospacedFamilies
        #expect(families.first?.id == EditorFontResolver.systemMonoId)
    }

    @Test("Editor font cache falls back for unknown font family")
    func editorCacheFallsBackForUnknownFamily() {
        let fonts = ThemeFonts(
            editorFontFamily: "NoSuchFamily-XYZ",
            editorFontSize: 13,
            dataGridFontFamily: "System Mono",
            dataGridFontSize: 13
        )
        let cache = EditorFontCache(from: fonts)
        #expect(cache.font.pointSize > 0)
    }

    @Test("Data grid cache falls back for unknown font family")
    func dataGridCacheFallsBackForUnknownFamily() {
        let fonts = ThemeFonts(
            editorFontFamily: "System Mono",
            editorFontSize: 13,
            dataGridFontFamily: "NoSuchFamily-XYZ",
            dataGridFontSize: 13
        )
        let cache = DataGridFontCacheResolved(from: fonts)
        #expect(cache.regular.pointSize > 0)
        #expect(cache.monoCharWidth > 0)
    }

    @Test("Resolver list has unique IDs")
    func resolverListHasUniqueIds() {
        let ids = EditorFontResolver.availableMonospacedFamilies.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Unknown family reports unavailable")
    func unknownFamilyUnavailable() {
        #expect(EditorFontResolver.isAvailable(familyId: "NoSuchFamily-XYZ") == false)
    }

    @Test("ThemeFonts decode keeps legacy family strings")
    func themeFontsDecodeKeepsLegacyStrings() throws {
        let json = #"{"editorFontFamily":"Menlo","editorFontSize":13,"dataGridFontFamily":"Monaco","dataGridFontSize":13}"#
        let decoded = try JSONDecoder().decode(ThemeFonts.self, from: Data(json.utf8))
        #expect(decoded.editorFontFamily == "Menlo")
        #expect(decoded.dataGridFontFamily == "Monaco")
    }

    @Test("All resolver font families are monospaced")
    func allResolverFamiliesAreMonospaced() {
        let families = EditorFontResolver.availableMonospacedFamilies
        for family in families where family.id != EditorFontResolver.systemMonoId {
            let font = EditorFontResolver.resolve(familyId: family.id, size: 12)
            #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
    }
}
