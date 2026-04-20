//
//  ThemeColors.swift
//  TablePro
//

import Foundation
import SwiftUI
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
    var windowBackground: String?
    var controlBackground: String?
    var cardBackground: String?
    var border: String?
    var primaryText: String?
    var secondaryText: String?
    var tertiaryText: String?
    var accentColor: String?
    var selectionBackground: String?
    var hoverBackground: String?
    var status: StatusColors
    var badges: BadgeColors

    static let defaultLight = UIThemeColors(
        windowBackground: nil,
        controlBackground: nil,
        cardBackground: nil,
        border: nil,
        primaryText: nil,
        secondaryText: nil,
        tertiaryText: nil,
        accentColor: nil,
        selectionBackground: nil,
        hoverBackground: nil,
        status: .defaultLight,
        badges: .defaultLight
    )

    init(
        windowBackground: String?,
        controlBackground: String?,
        cardBackground: String?,
        border: String?,
        primaryText: String?,
        secondaryText: String?,
        tertiaryText: String?,
        accentColor: String?,
        selectionBackground: String?,
        hoverBackground: String?,
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
        controlBackground = try container.decodeIfPresent(String.self, forKey: .controlBackground)
        cardBackground = try container.decodeIfPresent(String.self, forKey: .cardBackground)
        border = try container.decodeIfPresent(String.self, forKey: .border)
        primaryText = try container.decodeIfPresent(String.self, forKey: .primaryText)
        secondaryText = try container.decodeIfPresent(String.self, forKey: .secondaryText)
        tertiaryText = try container.decodeIfPresent(String.self, forKey: .tertiaryText)
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor)
        selectionBackground = try container.decodeIfPresent(String.self, forKey: .selectionBackground)
        hoverBackground = try container.decodeIfPresent(String.self, forKey: .hoverBackground)
        status = try container.decodeIfPresent(StatusColors.self, forKey: .status) ?? fallback.status
        badges = try container.decodeIfPresent(BadgeColors.self, forKey: .badges) ?? fallback.badges
    }
}

// MARK: - Sidebar Theme Colors

internal struct SidebarThemeColors: Codable, Equatable, Sendable {
    var background: String?
    var text: String?
    var selectedItem: String?
    var hover: String?
    var sectionHeader: String?

    static let defaultLight = SidebarThemeColors(
        background: nil,
        text: nil,
        selectedItem: nil,
        hover: nil,
        sectionHeader: nil
    )

    init(background: String?, text: String?, selectedItem: String?, hover: String?, sectionHeader: String?) {
        self.background = background
        self.text = text
        self.selectedItem = selectedItem
        self.hover = hover
        self.sectionHeader = sectionHeader
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        background = try container.decodeIfPresent(String.self, forKey: .background)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        selectedItem = try container.decodeIfPresent(String.self, forKey: .selectedItem)
        hover = try container.decodeIfPresent(String.self, forKey: .hover)
        sectionHeader = try container.decodeIfPresent(String.self, forKey: .sectionHeader)
    }
}

// MARK: - Toolbar Theme Colors

internal struct ToolbarThemeColors: Codable, Equatable, Sendable {
    var secondaryText: String?
    var tertiaryText: String?

    static let defaultLight = ToolbarThemeColors(
        secondaryText: nil,
        tertiaryText: nil
    )

    init(secondaryText: String?, tertiaryText: String?) {
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        secondaryText = try container.decodeIfPresent(String.self, forKey: .secondaryText)
        tertiaryText = try container.decodeIfPresent(String.self, forKey: .tertiaryText)
    }
}
