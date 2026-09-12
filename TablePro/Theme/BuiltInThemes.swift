import Foundation

/// Default Light and Default Dark are Swift, not JSON: they are the fallback every other theme is
/// measured against, so they cannot themselves be a file that fails to load. Their surround slots
/// stay on `system:` values, which keeps the unthemed app pixel-identical to before the theme
/// owned these surfaces and keeps the system's Increase Contrast and vibrancy adaptations.
internal enum BuiltInThemes {
    internal static let defaultLightId = "tablepro.default-light"
    internal static let defaultDarkId = "tablepro.default-dark"

    internal static let light = ThemeDefinition(
        id: defaultLightId,
        name: String(localized: "Default Light"),
        author: "TablePro",
        appearance: .light,
        editor: EditorThemeColors(
            background: .hex("#FFFFFF"),
            text: .hex("#000000"),
            cursor: .hex("#007AFF"),
            selection: .hex("#B4D8FD"),
            currentLine: .hex("#007AFF14"),
            currentStatement: .hex("#0A0A0A0F"),
            lineNumber: .hex("#8E8E93"),
            invisibles: .hex("#C7C7CC"),
            syntax: SyntaxThemeColors(
                keyword: .hex("#0A49A5"),
                string: .hex("#C41A16"),
                number: .hex("#6C36A9"),
                comment: .hex("#007400"),
                null: .hex("#C55B00"),
                operator: .hex("#000000"),
                function: .hex("#326D74"),
                type: .hex("#3F6E74")
            )
        ),
        dataGrid: systemDataGrid(
            modified: "#FFD60A4D",
            inserted: "#34C7594D",
            deleted: "#FF3B304D",
            deletedText: "#FF3B3080"
        ),
        status: StatusThemeColors(
            success: .hex("#248A3D"),
            warning: .hex("#C55B00"),
            error: .hex("#D70015")
        )
    )

    internal static let dark = ThemeDefinition(
        id: defaultDarkId,
        name: String(localized: "Default Dark"),
        author: "TablePro",
        appearance: .dark,
        editor: EditorThemeColors(
            background: .hex("#1E1E1E"),
            text: .hex("#D4D4D4"),
            cursor: .hex("#007AFF"),
            selection: .hex("#264F78"),
            currentLine: .hex("#007AFF14"),
            currentStatement: .hex("#FFFFFF0F"),
            lineNumber: .hex("#858585"),
            invisibles: .hex("#4D4D4D"),
            syntax: SyntaxThemeColors(
                keyword: .hex("#569CD6"),
                string: .hex("#CE9178"),
                number: .hex("#B5CEA8"),
                comment: .hex("#6A9955"),
                null: .hex("#FF8C00"),
                operator: .hex("#D4D4D4"),
                function: .hex("#DCDCAA"),
                type: .hex("#4EC9B0")
            )
        ),
        dataGrid: systemDataGrid(
            modified: "#FFD60A4D",
            inserted: "#32D74B26",
            deleted: "#FF453A26",
            deletedText: "#FF453A80"
        ),
        status: StatusThemeColors(
            success: .hex("#32D74B"),
            warning: .hex("#FF9F0A"),
            error: .hex("#FF453A")
        )
    )

    internal static let all: [ThemeDefinition] = [light, dark]

    internal static func `default`(for appearance: ThemeAppearance) -> ThemeDefinition {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }

    internal static func defaultId(for appearance: ThemeAppearance) -> String {
        `default`(for: appearance).id
    }

    private static func systemDataGrid(
        modified: String,
        inserted: String,
        deleted: String,
        deletedText: String
    ) -> DataGridThemeColors {
        DataGridThemeColors(
            background: .system(.controlBackground),
            text: .system(.label),
            alternateRow: .system(.alternatingContentBackgroundOdd),
            headerBackground: .system(.windowBackground),
            headerText: .system(.label),
            gridLine: .system(.grid),
            selection: .system(.selectedContentBackground),
            selectionText: .system(.alternateSelectedControlText),
            inactiveSelection: .system(.unemphasizedSelectedContentBackground),
            focusBorder: .system(.keyboardFocusIndicator),
            nullValue: .system(.secondaryLabel),
            boolTrue: .system(.label),
            boolFalse: .system(.label),
            rowNumber: .system(.secondaryLabel),
            modified: .hex(modified),
            inserted: .hex(inserted),
            deleted: .hex(deleted),
            deletedText: .hex(deletedText)
        )
    }
}
