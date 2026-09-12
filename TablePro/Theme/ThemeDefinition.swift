import Foundation

internal enum ThemeAppearance: String, Codable, CaseIterable, Sendable {
    case light
    case dark
}

internal struct SyntaxThemeColors: Equatable, Sendable {
    var keyword: ThemeColorValue
    var string: ThemeColorValue
    var number: ThemeColorValue
    var comment: ThemeColorValue
    var null: ThemeColorValue
    var `operator`: ThemeColorValue
    var function: ThemeColorValue
    var type: ThemeColorValue
}

internal struct EditorThemeColors: Equatable, Sendable {
    var background: ThemeColorValue
    var text: ThemeColorValue
    var cursor: ThemeColorValue
    var selection: ThemeColorValue
    var currentLine: ThemeColorValue
    var currentStatement: ThemeColorValue
    var lineNumber: ThemeColorValue
    var invisibles: ThemeColorValue
    var syntax: SyntaxThemeColors
}

internal struct DataGridThemeColors: Equatable, Sendable {
    var background: ThemeColorValue
    var text: ThemeColorValue
    var alternateRow: ThemeColorValue
    var headerBackground: ThemeColorValue
    var headerText: ThemeColorValue
    var gridLine: ThemeColorValue
    var selection: ThemeColorValue
    var selectionText: ThemeColorValue
    var inactiveSelection: ThemeColorValue
    var focusBorder: ThemeColorValue
    var nullValue: ThemeColorValue
    var boolTrue: ThemeColorValue
    var boolFalse: ThemeColorValue
    var rowNumber: ThemeColorValue
    var modified: ThemeColorValue
    var inserted: ThemeColorValue
    var deleted: ThemeColorValue
    var deletedText: ThemeColorValue
}

internal struct StatusThemeColors: Equatable, Sendable {
    var success: ThemeColorValue
    var warning: ThemeColorValue
    var error: ThemeColorValue
}

internal struct PanelThemeColors: Equatable, Sendable {
    var background: ThemeColorValue
    var controlBackground: ThemeColorValue
    var text: ThemeColorValue
    var secondaryText: ThemeColorValue
    var tertiaryText: ThemeColorValue
    var separator: ThemeColorValue
}

internal struct ThemeDefinition: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var author: String
    var appearance: ThemeAppearance
    var editor: EditorThemeColors
    var dataGrid: DataGridThemeColors
    var panel: PanelThemeColors
    var status: StatusThemeColors

    internal static let builtInPrefix = "tablepro."
    internal static let registryPrefix = "registry."
    internal static let userPrefix = "user."

    internal var isBuiltIn: Bool { id.hasPrefix(Self.builtInPrefix) }
    internal var isRegistry: Bool { id.hasPrefix(Self.registryPrefix) }
    internal var isEditable: Bool { !isBuiltIn && !isRegistry }
}

/// The single registry every slot goes through. A slot exists here because a call site reads it,
/// which is what `ThemeSlotCoverageTests` enforces: the previous schema let whole groups
/// ship with no reader at all, and nothing caught it. The gate, the theme editor and the document
/// decoder all enumerate this list rather than keeping their own copies.
internal enum ThemeSlot: String, CaseIterable, Sendable {
    case editorBackground = "content.editor.background"
    case editorText = "content.editor.text"
    case editorCursor = "content.editor.cursor"
    case editorSelection = "content.editor.selection"
    case editorCurrentLine = "content.editor.currentLine"
    case editorCurrentStatement = "content.editor.currentStatement"
    case editorLineNumber = "content.editor.lineNumber"
    case editorInvisibles = "content.editor.invisibles"

    case syntaxKeyword = "content.editor.syntax.keyword"
    case syntaxString = "content.editor.syntax.string"
    case syntaxNumber = "content.editor.syntax.number"
    case syntaxComment = "content.editor.syntax.comment"
    case syntaxNull = "content.editor.syntax.null"
    case syntaxOperator = "content.editor.syntax.operator"
    case syntaxFunction = "content.editor.syntax.function"
    case syntaxType = "content.editor.syntax.type"

    case gridBackground = "content.dataGrid.background"
    case gridText = "content.dataGrid.text"
    case gridAlternateRow = "content.dataGrid.alternateRow"
    case gridHeaderBackground = "content.dataGrid.headerBackground"
    case gridHeaderText = "content.dataGrid.headerText"
    case gridLine = "content.dataGrid.gridLine"
    case gridSelection = "content.dataGrid.selection"
    case gridSelectionText = "content.dataGrid.selectionText"
    case gridInactiveSelection = "content.dataGrid.inactiveSelection"
    case gridFocusBorder = "content.dataGrid.focusBorder"
    case gridNullValue = "content.dataGrid.nullValue"
    case gridBoolTrue = "content.dataGrid.boolTrue"
    case gridBoolFalse = "content.dataGrid.boolFalse"
    case gridRowNumber = "content.dataGrid.rowNumber"
    case gridModified = "content.dataGrid.modified"
    case gridInserted = "content.dataGrid.inserted"
    case gridDeleted = "content.dataGrid.deleted"
    case gridDeletedText = "content.dataGrid.deletedText"

    case panelBackground = "content.panel.background"
    case panelControlBackground = "content.panel.controlBackground"
    case panelText = "content.panel.text"
    case panelSecondaryText = "content.panel.secondaryText"
    case panelTertiaryText = "content.panel.tertiaryText"
    case panelSeparator = "content.panel.separator"

    case statusSuccess = "content.status.success"
    case statusWarning = "content.status.warning"
    case statusError = "content.status.error"


    internal var since: Int { 2 }

    internal var group: ThemeSlotGroup {
        switch self {
        case .editorBackground, .editorText, .editorCursor, .editorSelection,
             .editorCurrentLine, .editorCurrentStatement, .editorLineNumber, .editorInvisibles:
            return .editor
        case .syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxComment,
             .syntaxNull, .syntaxOperator, .syntaxFunction, .syntaxType:
            return .syntax
        case .gridBackground, .gridText, .gridAlternateRow, .gridHeaderBackground, .gridHeaderText,
             .gridLine, .gridSelection, .gridSelectionText, .gridInactiveSelection, .gridFocusBorder,
             .gridNullValue, .gridBoolTrue, .gridBoolFalse, .gridRowNumber,
             .gridModified, .gridInserted, .gridDeleted, .gridDeletedText:
            return .dataGrid
        case .panelBackground, .panelControlBackground, .panelText,
             .panelSecondaryText, .panelTertiaryText, .panelSeparator:
            return .panel
        case .statusSuccess, .statusWarning, .statusError:
            return .status
        }
    }

    internal var keyPath: WritableKeyPath<ThemeDefinition, ThemeColorValue> {
        switch self {
        case .editorBackground: return \.editor.background
        case .editorText: return \.editor.text
        case .editorCursor: return \.editor.cursor
        case .editorSelection: return \.editor.selection
        case .editorCurrentLine: return \.editor.currentLine
        case .editorCurrentStatement: return \.editor.currentStatement
        case .editorLineNumber: return \.editor.lineNumber
        case .editorInvisibles: return \.editor.invisibles

        case .syntaxKeyword: return \.editor.syntax.keyword
        case .syntaxString: return \.editor.syntax.string
        case .syntaxNumber: return \.editor.syntax.number
        case .syntaxComment: return \.editor.syntax.comment
        case .syntaxNull: return \.editor.syntax.null
        case .syntaxOperator: return \.editor.syntax.operator
        case .syntaxFunction: return \.editor.syntax.function
        case .syntaxType: return \.editor.syntax.type

        case .gridBackground: return \.dataGrid.background
        case .gridText: return \.dataGrid.text
        case .gridAlternateRow: return \.dataGrid.alternateRow
        case .gridHeaderBackground: return \.dataGrid.headerBackground
        case .gridHeaderText: return \.dataGrid.headerText
        case .gridLine: return \.dataGrid.gridLine
        case .gridSelection: return \.dataGrid.selection
        case .gridSelectionText: return \.dataGrid.selectionText
        case .gridInactiveSelection: return \.dataGrid.inactiveSelection
        case .gridFocusBorder: return \.dataGrid.focusBorder
        case .gridNullValue: return \.dataGrid.nullValue
        case .gridBoolTrue: return \.dataGrid.boolTrue
        case .gridBoolFalse: return \.dataGrid.boolFalse
        case .gridRowNumber: return \.dataGrid.rowNumber
        case .gridModified: return \.dataGrid.modified
        case .gridInserted: return \.dataGrid.inserted
        case .gridDeleted: return \.dataGrid.deleted
        case .gridDeletedText: return \.dataGrid.deletedText

        case .panelBackground: return \.panel.background
        case .panelControlBackground: return \.panel.controlBackground
        case .panelText: return \.panel.text
        case .panelSecondaryText: return \.panel.secondaryText
        case .panelTertiaryText: return \.panel.tertiaryText
        case .panelSeparator: return \.panel.separator

        case .statusSuccess: return \.status.success
        case .statusWarning: return \.status.warning
        case .statusError: return \.status.error

        }
    }

    internal var label: String {
        switch self {
        case .editorBackground, .gridBackground: return String(localized: "Background")
        case .editorText, .gridText: return String(localized: "Text")
        case .editorCursor: return String(localized: "Cursor")
        case .editorSelection, .gridSelection: return String(localized: "Selection")
        case .editorCurrentLine: return String(localized: "Current Line")
        case .editorCurrentStatement: return String(localized: "Current Statement")
        case .editorLineNumber: return String(localized: "Line Number")
        case .editorInvisibles: return String(localized: "Invisibles")
        case .syntaxKeyword: return String(localized: "Keyword")
        case .syntaxString: return String(localized: "String")
        case .syntaxNumber: return String(localized: "Number")
        case .syntaxComment: return String(localized: "Comment")
        case .syntaxNull: return String(localized: "NULL")
        case .syntaxOperator: return String(localized: "Operator")
        case .syntaxFunction: return String(localized: "Function")
        case .syntaxType: return String(localized: "Type")
        case .gridAlternateRow: return String(localized: "Alternate Row")
        case .gridHeaderBackground: return String(localized: "Header Background")
        case .gridHeaderText: return String(localized: "Header Text")
        case .gridLine: return String(localized: "Grid Line")
        case .gridSelectionText: return String(localized: "Selected Text")
        case .gridInactiveSelection: return String(localized: "Inactive Selection")
        case .gridFocusBorder: return String(localized: "Focus Border")
        case .gridNullValue: return String(localized: "NULL Value")
        case .gridBoolTrue: return String(localized: "Bool True")
        case .gridBoolFalse: return String(localized: "Bool False")
        case .gridRowNumber: return String(localized: "Row Number")
        case .gridModified: return String(localized: "Modified")
        case .gridInserted: return String(localized: "Inserted")
        case .gridDeleted: return String(localized: "Deleted")
        case .gridDeletedText: return String(localized: "Deleted Text")
        case .statusSuccess: return String(localized: "Success")
        case .statusWarning: return String(localized: "Warning")
        case .statusError: return String(localized: "Error")
        case .panelBackground: return String(localized: "Pane Background")
        case .panelControlBackground: return String(localized: "Field Background")
        case .panelText: return String(localized: "Pane Text")
        case .panelSecondaryText: return String(localized: "Secondary Text")
        case .panelTertiaryText: return String(localized: "Tertiary Text")
        case .panelSeparator: return String(localized: "Separator")
        }
    }
}

internal enum ThemeSlotGroup: String, CaseIterable, Sendable {
    case editor
    case syntax
    case dataGrid
    case panel
    case status

    internal var label: String {
        switch self {
        case .editor: return String(localized: "Editor")
        case .syntax: return String(localized: "Syntax Colors")
        case .dataGrid: return String(localized: "Data Grid")
        case .panel: return String(localized: "Panels")
        case .status: return String(localized: "Status")
        }
    }

    internal var slots: [ThemeSlot] {
        ThemeSlot.allCases.filter { $0.group == self }
    }
}

internal enum ThemeSchema {
    internal static let current = 2
    internal static let oldestSupported = 2
}
