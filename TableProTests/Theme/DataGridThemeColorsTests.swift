//
//  DataGridThemeColorsTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// Activates themes on the shared `ThemeEngine`. Every body that does is synchronous and
/// `@MainActor`, so nothing else on the main actor can run between activating a test theme and
/// restoring the original one.
@Suite("Data grid theme colors", .serialized)
@MainActor
struct DataGridThemeColorsTests {
    private static let systemDefaultedKeys = [
        "background", "text", "alternateRow", "nullValue", "boolTrue", "boolFalse", "rowNumber",
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sRGB(_ color: NSColor?) -> NSColor? {
        color?.usingColorSpace(.sRGB)
    }

    private func matches(_ lhs: NSColor?, _ hex: String) -> Bool {
        guard let lhs = sRGB(lhs), let rhs = sRGB(hex.nsColor) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }

    private func withTheme(_ configure: (inout DataGridThemeColors) -> Void, _ body: () throws -> Void) rethrows {
        let engine = ThemeEngine.shared
        let original = engine.activeTheme
        defer { engine.activateTheme(original) }
        var theme = ThemeDefinition.default
        theme.id = "test.grid-colors"
        configure(&theme.dataGrid)
        engine.activateTheme(theme)
        try body()
    }

    // MARK: - Decoding

    @Test("An undeclared grid color decodes as absent, a state tint as the default")
    func emptyGroupDecodes() throws {
        let decoded = try JSONDecoder().decode(DataGridThemeColors.self, from: Data("{}".utf8))

        #expect(decoded == DataGridThemeColors.defaultLight)
        #expect(decoded.background == nil)
        #expect(decoded.boolTrue == nil)
        #expect(decoded.modified == DataGridThemeColors.defaultLight.modified)
    }

    @Test("A theme written with focusBorder still decodes, and the key is dropped on save")
    func focusBorderIsIgnored() throws {
        let json = """
        { "background": "#282A36", "text": "#F8F8F2", "focusBorder": "#BD93F9", "deleted": "#FF555526" }
        """
        let decoded = try JSONDecoder().decode(DataGridThemeColors.self, from: Data(json.utf8))
        let encoded = try #require(String(data: JSONEncoder().encode(decoded), encoding: .utf8))

        #expect(decoded.background == "#282A36")
        #expect(decoded.text == "#F8F8F2")
        #expect(decoded.deleted == "#FF555526")
        #expect(!encoded.contains("focusBorder"))
    }

    @Test("An undeclared grid color is left out of the saved file")
    func undeclaredColorsAreNotWritten() throws {
        let encoded = try #require(String(data: JSONEncoder().encode(DataGridThemeColors.defaultLight), encoding: .utf8))

        for key in Self.systemDefaultedKeys {
            #expect(!encoded.contains("\"\(key)\""), "\(key) was written")
        }
    }

    // MARK: - Resolution

    @Test("An undeclared grid color resolves to the color the grid draws without a theme")
    func undeclaredColorsResolveToSystem() {
        let resolved = ResolvedDataGridColors(from: .defaultLight)

        #expect(resolved.background == .controlBackgroundColor)
        #expect(resolved.text == .labelColor)
        #expect(resolved.alternateRow == NSColor.alternatingContentBackgroundColors.last)
        #expect(resolved.nullValue == .secondaryLabelColor)
        #expect(resolved.rowNumber == .secondaryLabelColor)
        #expect(resolved.boolTrue == nil)
        #expect(resolved.boolFalse == nil)
    }

    @Test("A declared grid color resolves to its own value")
    func declaredColorsResolve() {
        var colors = DataGridThemeColors.defaultLight
        colors.background = "#102030"
        colors.text = "#405060"
        colors.alternateRow = "#708090"
        colors.nullValue = "#A0B0C0"
        colors.boolTrue = "#00FF00"
        colors.boolFalse = "#FF0000"
        colors.rowNumber = "#123456"
        let resolved = ResolvedDataGridColors(from: colors)

        #expect(matches(resolved.background, "#102030"))
        #expect(matches(resolved.text, "#405060"))
        #expect(matches(resolved.alternateRow, "#708090"))
        #expect(matches(resolved.nullValue, "#A0B0C0"))
        #expect(matches(resolved.boolTrue, "#00FF00"))
        #expect(matches(resolved.boolFalse, "#FF0000"))
        #expect(matches(resolved.rowNumber, "#123456"))
    }

    // MARK: - The grid reads them

    @Test("The table and its stripes take the theme's background and alternate row")
    func stripesFollowTheTheme() {
        withTheme({
            $0.background = "#102030"
            $0.alternateRow = "#708090"
        }) {
            let tableView = NSTableView()
            tableView.usesAlternatingRowBackgroundColors = true
            DataGridBodyChrome.applyBackground(to: tableView)

            #expect(matches(tableView.backgroundColor, "#102030"))
            #expect(matches(DataGridBodyChrome.stripeColor(forRow: 0, of: tableView), "#102030"))
            #expect(matches(DataGridBodyChrome.stripeColor(forRow: 1, of: tableView), "#708090"))
            #expect(matches(DataGridBodyChrome.rowBackgroundColor(forRow: 3, of: tableView), "#708090"))

            tableView.usesAlternatingRowBackgroundColors = false
            #expect(DataGridBodyChrome.stripeColor(forRow: 1, of: tableView) == nil)
            #expect(matches(DataGridBodyChrome.rowBackgroundColor(forRow: 1, of: tableView), "#102030"))
        }
    }

    @Test("Without grid colors the stripes are the pair NSTableView hands its rows")
    func stripesFallBackToSystem() {
        withTheme({ _ in }) {
            let tableView = NSTableView()
            tableView.usesAlternatingRowBackgroundColors = true
            DataGridBodyChrome.applyBackground(to: tableView)
            let system = NSColor.alternatingContentBackgroundColors

            #expect(tableView.backgroundColor == .controlBackgroundColor)
            #expect(DataGridBodyChrome.stripeColor(forRow: 0, of: tableView) == system.first)
            #expect(DataGridBodyChrome.stripeColor(forRow: 1, of: tableView) == system.last)
        }
    }

    @Test("Row numbers take the theme's color, and a deleted row's the deleted text")
    func rowNumberColor() {
        withTheme({
            $0.rowNumber = "#123456"
            $0.deletedText = "#FF000080"
        }) {
            let registry = DataGridCellRegistry()
            let deleted = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])

            #expect(matches(registry.rowNumberColor(for: .empty), "#123456"))
            #expect(matches(registry.rowNumberColor(for: deleted), "#FF000080"))
        }
    }

    @Test("The cell palette carries the theme's text, NULL and boolean colors")
    func paletteFollowsTheTheme() {
        withTheme({
            $0.text = "#405060"
            $0.nullValue = "#A0B0C0"
            $0.boolTrue = "#00FF00"
        }) {
            let palette = ThemeEngine.shared.dataGridCellPalette

            #expect(matches(palette.text, "#405060"))
            #expect(matches(palette.placeholderText, "#A0B0C0"))
            #expect(matches(palette.booleanTrueText, "#00FF00"))
            #expect(palette.booleanFalseText == nil)
        }
    }

    /// Eight of these keys were declared, editable and shipped in every theme while the grid drew
    /// system colors instead, so a theme could set them and see nothing change.
    @Test("Every data grid theme color is read by the grid")
    func everyKeyHasAGridReader() throws {
        let keys = Mirror(reflecting: DataGridThemeColors.defaultLight).children.compactMap(\.label)
        let resultsDirectory = Self.repositoryRoot.appendingPathComponent("TablePro/Views/Results", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: resultsDirectory, includingPropertiesForKeys: nil))
        var source = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            source += try String(contentsOf: url, encoding: .utf8)
        }

        #expect(!keys.isEmpty)
        for key in keys {
            #expect(source.contains("dataGrid.\(key)"), "No grid code reads the \(key) theme color")
        }
    }

    // MARK: - Bundled themes

    private func dataGridGroup(ofTheme id: String) throws -> [String: Any] {
        let url = Self.repositoryRoot.appendingPathComponent("TablePro/Resources/Themes/\(id).json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try #require(json?["dataGrid"] as? [String: Any])
    }

    @Test("The default themes leave the grid on system colors", arguments: [
        "tablepro.default-light", "tablepro.default-dark",
    ])
    func defaultThemesDeclareNoGridColors(id: String) throws {
        let group = try dataGridGroup(ofTheme: id)

        for key in Self.systemDefaultedKeys + ["focusBorder"] {
            #expect(group[key] == nil, "\(id) declares \(key)")
        }
    }

    @Test("The designed themes declare every grid color", arguments: ["tablepro.dracula", "tablepro.nord"])
    func designedThemesDeclareGridColors(id: String) throws {
        let group = try dataGridGroup(ofTheme: id)

        for key in Self.systemDefaultedKeys {
            #expect((group[key] as? String)?.isEmpty == false, "\(id) omits \(key)")
        }
        #expect(group["focusBorder"] == nil)
    }
}
