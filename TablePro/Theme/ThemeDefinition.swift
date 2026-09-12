import SwiftUI

internal struct ThemeDefinition: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var version: Int
    var appearance: ThemeAppearance
    var author: String
    var editor: EditorThemeColors
    var dataGrid: DataGridThemeColors
    var ui: UIThemeColors
    var sidebar: SidebarThemeColors
    var toolbar: ToolbarThemeColors
    var fonts: ThemeFonts

    var isBuiltIn: Bool { id.hasPrefix("tablepro.") }
    var isRegistry: Bool { id.hasPrefix("registry.") }
    var isEditable: Bool { !isBuiltIn && !isRegistry }

    static let `default` = ThemeDefinition(
        id: "tablepro.default-light",
        name: "Default Light",
        version: 1,
        appearance: .light,
        author: "TablePro",
        editor: .defaultLight,
        dataGrid: .defaultLight,
        ui: .defaultLight,
        sidebar: .defaultLight,
        toolbar: .defaultLight,
        fonts: .default
    )

    init(
        id: String,
        name: String,
        version: Int,
        appearance: ThemeAppearance,
        author: String,
        editor: EditorThemeColors,
        dataGrid: DataGridThemeColors,
        ui: UIThemeColors,
        sidebar: SidebarThemeColors,
        toolbar: ToolbarThemeColors,
        fonts: ThemeFonts
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.appearance = appearance
        self.author = author
        self.editor = editor
        self.dataGrid = dataGrid
        self.ui = ui
        self.sidebar = sidebar
        self.toolbar = toolbar
        self.fonts = fonts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeDefinition.default

        id = try container.decodeIfPresent(String.self, forKey: .id) ?? fallback.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? fallback.name
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? fallback.version
        appearance = try container.decodeIfPresent(ThemeAppearance.self, forKey: .appearance) ?? fallback.appearance
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? fallback.author
        editor = try container.decodeIfPresent(EditorThemeColors.self, forKey: .editor) ?? fallback.editor
        dataGrid = try container.decodeIfPresent(DataGridThemeColors.self, forKey: .dataGrid) ?? fallback.dataGrid
        ui = try container.decodeIfPresent(UIThemeColors.self, forKey: .ui) ?? fallback.ui
        sidebar = try container.decodeIfPresent(SidebarThemeColors.self, forKey: .sidebar) ?? fallback.sidebar
        toolbar = try container.decodeIfPresent(ToolbarThemeColors.self, forKey: .toolbar) ?? fallback.toolbar
        fonts = try container.decodeIfPresent(ThemeFonts.self, forKey: .fonts) ?? fallback.fonts
    }
}

internal enum ThemeAppearance: String, Codable, Sendable {
    case light, dark, auto
}
