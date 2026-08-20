//
//  BundledThemeStatementHighlightTests.swift
//  TableProTests
//
//  `EditorThemeColors` falls back to the light defaults for any key a theme omits, so a dark theme that forgets
//  `currentStatementHighlight` paints the light value over dark text. Nothing at runtime notices, which is why this
//  reads the shipped JSON rather than the decoded theme.
//

import Foundation
import Testing
@testable import TablePro

@Suite("Bundled themes declare a statement highlight")
struct BundledThemeStatementHighlightTests {

    private static let themeIds = [
        "tablepro.default-light",
        "tablepro.default-dark",
        "tablepro.dracula",
        "tablepro.nord",
    ]

    private static var themesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TablePro/Resources/Themes", isDirectory: true)
    }

    private func editorColors(for id: String) throws -> [String: Any] {
        let url = Self.themesDirectory.appendingPathComponent("\(id).json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let editor = json?["editor"] as? [String: Any]
        return try #require(editor)
    }

    @Test("Every bundled theme declares currentStatementHighlight", arguments: themeIds)
    func themeDeclaresStatementHighlight(id: String) throws {
        let colors = try editorColors(for: id)
        let value = colors["currentStatementHighlight"] as? String
        #expect(value?.isEmpty == false, "\(id) omits currentStatementHighlight")
    }

    /// A band the same colour as the caret line or the selection tells the reader nothing. Dracula and Nord already
    /// set those two equal to each other, so the collision is live rather than hypothetical.
    @Test("The statement highlight differs from the line highlight and the selection", arguments: themeIds)
    func statementHighlightIsDistinct(id: String) throws {
        let colors = try editorColors(for: id)
        let statement = colors["currentStatementHighlight"] as? String

        #expect(statement != colors["currentLineHighlight"] as? String, "\(id): band matches the caret line")
        #expect(statement != colors["selection"] as? String, "\(id): band matches the selection")
        #expect(statement != colors["background"] as? String, "\(id): band matches the background")
    }

    /// The band is painted under the caret line highlight, so it has to layer with it rather than cover it.
    @Test("The statement highlight carries alpha", arguments: themeIds)
    func statementHighlightCarriesAlpha(id: String) throws {
        let colors = try editorColors(for: id)
        let value = try #require(colors["currentStatementHighlight"] as? String)

        #expect(value.count == 9, "\(id): expected #RRGGBBAA, got \(value)")
    }
}
