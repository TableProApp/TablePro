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
    var spacing: ThemeSpacing
    var typography: ThemeTypography
    var iconSizes: ThemeIconSizes
    var cornerRadius: ThemeCornerRadius
    var rowHeights: ThemeRowHeights
    var animations: ThemeAnimations

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
        fonts: .default,
        spacing: .default,
        typography: .default,
        iconSizes: .default,
        cornerRadius: .default,
        rowHeights: .default,
        animations: .default
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
        fonts: ThemeFonts,
        spacing: ThemeSpacing = .default,
        typography: ThemeTypography = .default,
        iconSizes: ThemeIconSizes = .default,
        cornerRadius: ThemeCornerRadius = .default,
        rowHeights: ThemeRowHeights = .default,
        animations: ThemeAnimations = .default
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
        self.spacing = spacing
        self.typography = typography
        self.iconSizes = iconSizes
        self.cornerRadius = cornerRadius
        self.rowHeights = rowHeights
        self.animations = animations
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
        spacing = try container.decodeIfPresent(ThemeSpacing.self, forKey: .spacing) ?? fallback.spacing
        typography = try container.decodeIfPresent(ThemeTypography.self, forKey: .typography) ?? fallback.typography
        iconSizes = try container.decodeIfPresent(ThemeIconSizes.self, forKey: .iconSizes) ?? fallback.iconSizes
        cornerRadius = try container.decodeIfPresent(ThemeCornerRadius.self, forKey: .cornerRadius) ?? fallback.cornerRadius
        rowHeights = try container.decodeIfPresent(ThemeRowHeights.self, forKey: .rowHeights) ?? fallback.rowHeights
        animations = try container.decodeIfPresent(ThemeAnimations.self, forKey: .animations) ?? fallback.animations
    }
}

internal enum ThemeAppearance: String, Codable, Sendable {
    case light, dark, auto
}

// MARK: - Syntax Colors

internal struct SyntaxColors: Codable, Equatable, Sendable {
    var keyword: String
    var string: String
    var number: String
    var comment: String
    var null: String
    var `operator`: String
    var function: String
    var type: String

    static let defaultLight = SyntaxColors(
        keyword: "#9B2393",
        string: "#C41A16",
        number: "#1C00CF",
        comment: "#5D6C79",
        null: "#9B2393",
        operator: "#000000",
        function: "#326D74",
        type: "#3F6E74"
    )

    init(
        keyword: String,
        string: String,
        number: String,
        comment: String,
        null: String,
        operator: String,
        function: String,
        type: String
    ) {
        self.keyword = keyword
        self.string = string
        self.number = number
        self.comment = comment
        self.null = null
        self.operator = `operator`
        self.function = function
        self.type = type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SyntaxColors.defaultLight

        keyword = try container.decodeIfPresent(String.self, forKey: .keyword) ?? fallback.keyword
        string = try container.decodeIfPresent(String.self, forKey: .string) ?? fallback.string
        number = try container.decodeIfPresent(String.self, forKey: .number) ?? fallback.number
        comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? fallback.comment
        null = try container.decodeIfPresent(String.self, forKey: .null) ?? fallback.null
        `operator` = try container.decodeIfPresent(String.self, forKey: .operator) ?? fallback.operator
        function = try container.decodeIfPresent(String.self, forKey: .function) ?? fallback.function
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? fallback.type
    }
}

// MARK: - Editor Theme Colors

internal struct EditorThemeColors: Codable, Equatable, Sendable {
    var background: String
    var text: String
    var cursor: String
    var currentLineHighlight: String
    var selection: String
    var lineNumber: String
    var invisibles: String
    /// Reserved for future current-statement background highlight in the query editor.
    var currentStatementHighlight: String
    var syntax: SyntaxColors

    static let defaultLight = EditorThemeColors(
        background: "#FFFFFF",
        text: "#000000",
        cursor: "#000000",
        currentLineHighlight: "#ECF5FF",
        selection: "#B4D8FD",
        lineNumber: "#747478",
        invisibles: "#D6D6D6",
        currentStatementHighlight: "#F0F4FA",
        syntax: .defaultLight
    )

    init(
        background: String,
        text: String,
        cursor: String,
        currentLineHighlight: String,
        selection: String,
        lineNumber: String,
        invisibles: String,
        currentStatementHighlight: String,
        syntax: SyntaxColors
    ) {
        self.background = background
        self.text = text
        self.cursor = cursor
        self.currentLineHighlight = currentLineHighlight
        self.selection = selection
        self.lineNumber = lineNumber
        self.invisibles = invisibles
        self.currentStatementHighlight = currentStatementHighlight
        self.syntax = syntax
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = EditorThemeColors.defaultLight

        background = try container.decodeIfPresent(String.self, forKey: .background) ?? fallback.background
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? fallback.text
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor) ?? fallback.cursor
        currentLineHighlight = try container.decodeIfPresent(String.self, forKey: .currentLineHighlight)
            ?? fallback.currentLineHighlight
        selection = try container.decodeIfPresent(String.self, forKey: .selection) ?? fallback.selection
        lineNumber = try container.decodeIfPresent(String.self, forKey: .lineNumber) ?? fallback.lineNumber
        invisibles = try container.decodeIfPresent(String.self, forKey: .invisibles) ?? fallback.invisibles
        currentStatementHighlight = try container.decodeIfPresent(String.self, forKey: .currentStatementHighlight)
            ?? fallback.currentStatementHighlight
        syntax = try container.decodeIfPresent(SyntaxColors.self, forKey: .syntax) ?? fallback.syntax
    }
}

// MARK: - Data Grid Theme Colors

internal struct DataGridThemeColors: Codable, Equatable, Sendable {
    var background: String
    var text: String
    var alternateRow: String
    var nullValue: String
    var boolTrue: String
    var boolFalse: String
    var rowNumber: String
    var modified: String
    var inserted: String
    var deleted: String
    var deletedText: String
    var focusBorder: String

    static let defaultLight = DataGridThemeColors(
        background: "#FFFFFF",
        text: "#000000",
        alternateRow: "#F5F5F5",
        nullValue: "#B0B0B0",
        boolTrue: "#34A853",
        boolFalse: "#EA4335",
        rowNumber: "#747478",
        modified: "#FFF9C4",
        inserted: "#E8F5E9",
        deleted: "#FFEBEE",
        deletedText: "#B0B0B0",
        focusBorder: "#2196F3"
    )

    init(
        background: String,
        text: String,
        alternateRow: String,
        nullValue: String,
        boolTrue: String,
        boolFalse: String,
        rowNumber: String,
        modified: String,
        inserted: String,
        deleted: String,
        deletedText: String,
        focusBorder: String
    ) {
        self.background = background
        self.text = text
        self.alternateRow = alternateRow
        self.nullValue = nullValue
        self.boolTrue = boolTrue
        self.boolFalse = boolFalse
        self.rowNumber = rowNumber
        self.modified = modified
        self.inserted = inserted
        self.deleted = deleted
        self.deletedText = deletedText
        self.focusBorder = focusBorder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DataGridThemeColors.defaultLight

        background = try container.decodeIfPresent(String.self, forKey: .background) ?? fallback.background
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? fallback.text
        alternateRow = try container.decodeIfPresent(String.self, forKey: .alternateRow) ?? fallback.alternateRow
        nullValue = try container.decodeIfPresent(String.self, forKey: .nullValue) ?? fallback.nullValue
        boolTrue = try container.decodeIfPresent(String.self, forKey: .boolTrue) ?? fallback.boolTrue
        boolFalse = try container.decodeIfPresent(String.self, forKey: .boolFalse) ?? fallback.boolFalse
        rowNumber = try container.decodeIfPresent(String.self, forKey: .rowNumber) ?? fallback.rowNumber
        modified = try container.decodeIfPresent(String.self, forKey: .modified) ?? fallback.modified
        inserted = try container.decodeIfPresent(String.self, forKey: .inserted) ?? fallback.inserted
        deleted = try container.decodeIfPresent(String.self, forKey: .deleted) ?? fallback.deleted
        deletedText = try container.decodeIfPresent(String.self, forKey: .deletedText) ?? fallback.deletedText
        focusBorder = try container.decodeIfPresent(String.self, forKey: .focusBorder) ?? fallback.focusBorder
    }
}

// MARK: - Status Colors

internal struct StatusColors: Codable, Equatable, Sendable {
    var success: String
    var warning: String
    var error: String
    var info: String

    static let defaultLight = StatusColors(
        success: "#34A853",
        warning: "#FBBC04",
        error: "#EA4335",
        info: "#4285F4"
    )

    init(success: String, warning: String, error: String, info: String) {
        self.success = success
        self.warning = warning
        self.error = error
        self.info = info
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = StatusColors.defaultLight

        success = try container.decodeIfPresent(String.self, forKey: .success) ?? fallback.success
        warning = try container.decodeIfPresent(String.self, forKey: .warning) ?? fallback.warning
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? fallback.error
        info = try container.decodeIfPresent(String.self, forKey: .info) ?? fallback.info
    }
}

// MARK: - Badge Colors

internal struct BadgeColors: Codable, Equatable, Sendable {
    var background: String
    var primaryKey: String
    var autoIncrement: String

    static let defaultLight = BadgeColors(
        background: "#E8E8ED",
        primaryKey: "#FFCC00",
        autoIncrement: "#AF52DE"
    )

    init(background: String, primaryKey: String, autoIncrement: String) {
        self.background = background
        self.primaryKey = primaryKey
        self.autoIncrement = autoIncrement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BadgeColors.defaultLight

        background = try container.decodeIfPresent(String.self, forKey: .background) ?? fallback.background
        primaryKey = try container.decodeIfPresent(String.self, forKey: .primaryKey) ?? fallback.primaryKey
        autoIncrement = try container.decodeIfPresent(String.self, forKey: .autoIncrement) ?? fallback.autoIncrement
    }
}

// MARK: - UI Theme Colors

internal struct UIThemeColors: Codable, Equatable, Sendable {
    var windowBackground: String
    var controlBackground: String
    var cardBackground: String
    var border: String
    var primaryText: String
    var secondaryText: String
    var tertiaryText: String
    var accentColor: String?
    var selectionBackground: String
    var hoverBackground: String
    var status: StatusColors
    var badges: BadgeColors

    static let defaultLight = UIThemeColors(
        windowBackground: "#ECECEC",
        controlBackground: "#FFFFFF",
        cardBackground: "#FFFFFF",
        border: "#D1D1D6",
        primaryText: "#000000",
        secondaryText: "#3C3C43",
        tertiaryText: "#8E8E93",
        accentColor: nil,
        selectionBackground: "#0A84FF",
        hoverBackground: "#F2F2F7",
        status: .defaultLight,
        badges: .defaultLight
    )

    init(
        windowBackground: String,
        controlBackground: String,
        cardBackground: String,
        border: String,
        primaryText: String,
        secondaryText: String,
        tertiaryText: String,
        accentColor: String?,
        selectionBackground: String,
        hoverBackground: String,
        status: StatusColors,
        badges: BadgeColors
    ) {
        self.windowBackground = windowBackground
        self.controlBackground = controlBackground
        self.cardBackground = cardBackground
        self.border = border
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.accentColor = accentColor
        self.selectionBackground = selectionBackground
        self.hoverBackground = hoverBackground
        self.status = status
        self.badges = badges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = UIThemeColors.defaultLight

        windowBackground = try container.decodeIfPresent(String.self, forKey: .windowBackground)
            ?? fallback.windowBackground
        controlBackground = try container.decodeIfPresent(String.self, forKey: .controlBackground)
            ?? fallback.controlBackground
        cardBackground = try container.decodeIfPresent(String.self, forKey: .cardBackground) ?? fallback.cardBackground
        border = try container.decodeIfPresent(String.self, forKey: .border) ?? fallback.border
        primaryText = try container.decodeIfPresent(String.self, forKey: .primaryText) ?? fallback.primaryText
        secondaryText = try container.decodeIfPresent(String.self, forKey: .secondaryText) ?? fallback.secondaryText
        tertiaryText = try container.decodeIfPresent(String.self, forKey: .tertiaryText) ?? fallback.tertiaryText
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor)
        selectionBackground = try container.decodeIfPresent(String.self, forKey: .selectionBackground)
            ?? fallback.selectionBackground
        hoverBackground = try container.decodeIfPresent(String.self, forKey: .hoverBackground)
            ?? fallback.hoverBackground
        status = try container.decodeIfPresent(StatusColors.self, forKey: .status) ?? fallback.status
        badges = try container.decodeIfPresent(BadgeColors.self, forKey: .badges) ?? fallback.badges
    }
}

// MARK: - Sidebar Theme Colors

internal struct SidebarThemeColors: Codable, Equatable, Sendable {
    var background: String
    var text: String
    var selectedItem: String
    var hover: String
    var sectionHeader: String

    static let defaultLight = SidebarThemeColors(
        background: "#F5F5F5",
        text: "#000000",
        selectedItem: "#0A84FF",
        hover: "#E5E5EA",
        sectionHeader: "#8E8E93"
    )

    init(background: String, text: String, selectedItem: String, hover: String, sectionHeader: String) {
        self.background = background
        self.text = text
        self.selectedItem = selectedItem
        self.hover = hover
        self.sectionHeader = sectionHeader
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SidebarThemeColors.defaultLight

        background = try container.decodeIfPresent(String.self, forKey: .background) ?? fallback.background
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? fallback.text
        selectedItem = try container.decodeIfPresent(String.self, forKey: .selectedItem) ?? fallback.selectedItem
        hover = try container.decodeIfPresent(String.self, forKey: .hover) ?? fallback.hover
        sectionHeader = try container.decodeIfPresent(String.self, forKey: .sectionHeader) ?? fallback.sectionHeader
    }
}

// MARK: - Toolbar Theme Colors

internal struct ToolbarThemeColors: Codable, Equatable, Sendable {
    var secondaryText: String
    var tertiaryText: String

    static let defaultLight = ToolbarThemeColors(
        secondaryText: "#3C3C43",
        tertiaryText: "#8E8E93"
    )

    init(secondaryText: String, tertiaryText: String) {
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ToolbarThemeColors.defaultLight

        secondaryText = try container.decodeIfPresent(String.self, forKey: .secondaryText) ?? fallback.secondaryText
        tertiaryText = try container.decodeIfPresent(String.self, forKey: .tertiaryText) ?? fallback.tertiaryText
    }
}

// MARK: - Theme Fonts

internal struct ThemeFonts: Codable, Equatable, Sendable {
    var editorFontFamily: String
    var editorFontSize: Int
    var dataGridFontFamily: String
    var dataGridFontSize: Int

    static let `default` = ThemeFonts(
        editorFontFamily: "System Mono",
        editorFontSize: 13,
        dataGridFontFamily: "System Mono",
        dataGridFontSize: 13
    )

    init(editorFontFamily: String, editorFontSize: Int, dataGridFontFamily: String, dataGridFontSize: Int) {
        self.editorFontFamily = editorFontFamily
        self.editorFontSize = editorFontSize
        self.dataGridFontFamily = dataGridFontFamily
        self.dataGridFontSize = dataGridFontSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeFonts.default

        editorFontFamily = try container.decodeIfPresent(String.self, forKey: .editorFontFamily)
            ?? fallback.editorFontFamily
        editorFontSize = try container.decodeIfPresent(Int.self, forKey: .editorFontSize) ?? fallback.editorFontSize
        dataGridFontFamily = try container.decodeIfPresent(String.self, forKey: .dataGridFontFamily)
            ?? fallback.dataGridFontFamily
        dataGridFontSize = try container.decodeIfPresent(Int.self, forKey: .dataGridFontSize)
            ?? fallback.dataGridFontSize
    }
}

// MARK: - Theme Spacing

internal struct ThemeSpacing: Codable, Equatable, Sendable {
    var xxxs: CGFloat
    var xxs: CGFloat
    var xs: CGFloat
    var sm: CGFloat
    var md: CGFloat
    var lg: CGFloat
    var xl: CGFloat
    var listRowInsets: ThemeEdgeInsets

    static let `default` = ThemeSpacing(
        xxxs: 2, xxs: 4, xs: 8, sm: 12, md: 16, lg: 20, xl: 24,
        listRowInsets: .default
    )

    init(
        xxxs: CGFloat, xxs: CGFloat, xs: CGFloat, sm: CGFloat,
        md: CGFloat, lg: CGFloat, xl: CGFloat, listRowInsets: ThemeEdgeInsets
    ) {
        self.xxxs = xxxs; self.xxs = xxs; self.xs = xs; self.sm = sm
        self.md = md; self.lg = lg; self.xl = xl; self.listRowInsets = listRowInsets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeSpacing.default
        xxxs = try container.decodeIfPresent(CGFloat.self, forKey: .xxxs) ?? fallback.xxxs
        xxs = try container.decodeIfPresent(CGFloat.self, forKey: .xxs) ?? fallback.xxs
        xs = try container.decodeIfPresent(CGFloat.self, forKey: .xs) ?? fallback.xs
        sm = try container.decodeIfPresent(CGFloat.self, forKey: .sm) ?? fallback.sm
        md = try container.decodeIfPresent(CGFloat.self, forKey: .md) ?? fallback.md
        lg = try container.decodeIfPresent(CGFloat.self, forKey: .lg) ?? fallback.lg
        xl = try container.decodeIfPresent(CGFloat.self, forKey: .xl) ?? fallback.xl
        listRowInsets = try container.decodeIfPresent(ThemeEdgeInsets.self, forKey: .listRowInsets) ?? fallback.listRowInsets
    }
}

internal struct ThemeEdgeInsets: Codable, Equatable, Sendable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let `default` = ThemeEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

    var swiftUI: EdgeInsets { EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing) }
    var appKit: NSEdgeInsets { NSEdgeInsets(top: top, left: leading, bottom: bottom, right: trailing) }

    init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeEdgeInsets.default
        top = try container.decodeIfPresent(CGFloat.self, forKey: .top) ?? fallback.top
        leading = try container.decodeIfPresent(CGFloat.self, forKey: .leading) ?? fallback.leading
        bottom = try container.decodeIfPresent(CGFloat.self, forKey: .bottom) ?? fallback.bottom
        trailing = try container.decodeIfPresent(CGFloat.self, forKey: .trailing) ?? fallback.trailing
    }
}

// MARK: - Theme Typography

internal struct ThemeTypography: Codable, Equatable, Sendable {
    var tiny: CGFloat
    var caption: CGFloat
    var small: CGFloat
    var medium: CGFloat
    var body: CGFloat
    var title3: CGFloat
    var title2: CGFloat

    static let `default` = ThemeTypography(
        tiny: 9, caption: 10, small: 11, medium: 12, body: 13, title3: 15, title2: 17
    )

    init(
        tiny: CGFloat, caption: CGFloat, small: CGFloat, medium: CGFloat,
        body: CGFloat, title3: CGFloat, title2: CGFloat
    ) {
        self.tiny = tiny; self.caption = caption; self.small = small; self.medium = medium
        self.body = body; self.title3 = title3; self.title2 = title2
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeTypography.default
        tiny = try container.decodeIfPresent(CGFloat.self, forKey: .tiny) ?? fallback.tiny
        caption = try container.decodeIfPresent(CGFloat.self, forKey: .caption) ?? fallback.caption
        small = try container.decodeIfPresent(CGFloat.self, forKey: .small) ?? fallback.small
        medium = try container.decodeIfPresent(CGFloat.self, forKey: .medium) ?? fallback.medium
        body = try container.decodeIfPresent(CGFloat.self, forKey: .body) ?? fallback.body
        title3 = try container.decodeIfPresent(CGFloat.self, forKey: .title3) ?? fallback.title3
        title2 = try container.decodeIfPresent(CGFloat.self, forKey: .title2) ?? fallback.title2
    }
}

// MARK: - Theme Icon Sizes

internal struct ThemeIconSizes: Codable, Equatable, Sendable {
    var tinyDot: CGFloat
    var statusDot: CGFloat
    var small: CGFloat
    var `default`: CGFloat
    var medium: CGFloat
    var large: CGFloat
    var extraLarge: CGFloat
    var huge: CGFloat
    var massive: CGFloat

    static let `default` = ThemeIconSizes(
        tinyDot: 6, statusDot: 8, small: 12, default: 14, medium: 16,
        large: 20, extraLarge: 24, huge: 32, massive: 64
    )

    init(
        tinyDot: CGFloat, statusDot: CGFloat, small: CGFloat, `default`: CGFloat,
        medium: CGFloat, large: CGFloat, extraLarge: CGFloat, huge: CGFloat, massive: CGFloat
    ) {
        self.tinyDot = tinyDot; self.statusDot = statusDot; self.small = small
        self.`default` = `default`; self.medium = medium; self.large = large
        self.extraLarge = extraLarge; self.huge = huge; self.massive = massive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeIconSizes.default
        tinyDot = try container.decodeIfPresent(CGFloat.self, forKey: .tinyDot) ?? fallback.tinyDot
        statusDot = try container.decodeIfPresent(CGFloat.self, forKey: .statusDot) ?? fallback.statusDot
        small = try container.decodeIfPresent(CGFloat.self, forKey: .small) ?? fallback.small
        `default` = try container.decodeIfPresent(CGFloat.self, forKey: .default) ?? fallback.default
        medium = try container.decodeIfPresent(CGFloat.self, forKey: .medium) ?? fallback.medium
        large = try container.decodeIfPresent(CGFloat.self, forKey: .large) ?? fallback.large
        extraLarge = try container.decodeIfPresent(CGFloat.self, forKey: .extraLarge) ?? fallback.extraLarge
        huge = try container.decodeIfPresent(CGFloat.self, forKey: .huge) ?? fallback.huge
        massive = try container.decodeIfPresent(CGFloat.self, forKey: .massive) ?? fallback.massive
    }
}

// MARK: - Theme Corner Radius

internal struct ThemeCornerRadius: Codable, Equatable, Sendable {
    var small: CGFloat
    var medium: CGFloat
    var large: CGFloat

    static let `default` = ThemeCornerRadius(small: 4, medium: 6, large: 8)

    init(small: CGFloat, medium: CGFloat, large: CGFloat) {
        self.small = small; self.medium = medium; self.large = large
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeCornerRadius.default
        small = try container.decodeIfPresent(CGFloat.self, forKey: .small) ?? fallback.small
        medium = try container.decodeIfPresent(CGFloat.self, forKey: .medium) ?? fallback.medium
        large = try container.decodeIfPresent(CGFloat.self, forKey: .large) ?? fallback.large
    }
}

// MARK: - Theme Row Heights

internal struct ThemeRowHeights: Codable, Equatable, Sendable {
    var compact: CGFloat
    var table: CGFloat
    var comfortable: CGFloat

    static let `default` = ThemeRowHeights(compact: 24, table: 32, comfortable: 44)

    init(compact: CGFloat, table: CGFloat, comfortable: CGFloat) {
        self.compact = compact; self.table = table; self.comfortable = comfortable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeRowHeights.default
        compact = try container.decodeIfPresent(CGFloat.self, forKey: .compact) ?? fallback.compact
        table = try container.decodeIfPresent(CGFloat.self, forKey: .table) ?? fallback.table
        comfortable = try container.decodeIfPresent(CGFloat.self, forKey: .comfortable) ?? fallback.comfortable
    }
}

// MARK: - Theme Animations

internal struct ThemeAnimations: Codable, Equatable, Sendable {
    var fast: Double
    var normal: Double
    var smooth: Double
    var slow: Double

    static let `default` = ThemeAnimations(fast: 0.1, normal: 0.15, smooth: 0.2, slow: 0.3)

    init(fast: Double, normal: Double, smooth: Double, slow: Double) {
        self.fast = fast; self.normal = normal; self.smooth = smooth; self.slow = slow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThemeAnimations.default
        fast = try container.decodeIfPresent(Double.self, forKey: .fast) ?? fallback.fast
        normal = try container.decodeIfPresent(Double.self, forKey: .normal) ?? fallback.normal
        smooth = try container.decodeIfPresent(Double.self, forKey: .smooth) ?? fallback.smooth
        slow = try container.decodeIfPresent(Double.self, forKey: .slow) ?? fallback.slow
    }
}
