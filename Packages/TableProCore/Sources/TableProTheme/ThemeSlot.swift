import Foundation

/// The single registry every slot goes through. A slot exists here because a call site reads it.
/// The decoder, the encoder and the theme editor all enumerate this list rather than keeping their
/// own copies.
public enum ThemeSlot: String, CaseIterable, Sendable {
    case windowBackdrop = "window.background"

    case editorBackground = "editor.background"
    case editorText = "editor.text"
    case editorCursor = "editor.cursor"
    case editorSelection = "editor.selection"
    case editorCurrentLine = "editor.currentLine"
    case editorCurrentStatement = "editor.currentStatement"
    case editorLineNumber = "editor.lineNumber"
    case editorInvisibles = "editor.invisibles"

    case syntaxKeyword = "editor.syntax.keyword"
    case syntaxString = "editor.syntax.string"
    case syntaxNumber = "editor.syntax.number"
    case syntaxComment = "editor.syntax.comment"
    case syntaxNull = "editor.syntax.null"
    case syntaxOperator = "editor.syntax.operator"
    case syntaxFunction = "editor.syntax.function"
    case syntaxType = "editor.syntax.type"

    case gridBackground = "dataGrid.background"
    case gridText = "dataGrid.text"
    case gridAlternateRow = "dataGrid.alternateRow"
    case gridHeaderBackground = "dataGrid.headerBackground"
    case gridHeaderText = "dataGrid.headerText"
    case gridLine = "dataGrid.gridLine"
    case gridSelection = "dataGrid.selection"
    case gridSelectionText = "dataGrid.selectionText"
    case gridInactiveSelection = "dataGrid.inactiveSelection"
    case gridFocusBorder = "dataGrid.focusBorder"
    case gridNullValue = "dataGrid.nullValue"
    case gridBoolTrue = "dataGrid.boolTrue"
    case gridBoolFalse = "dataGrid.boolFalse"
    case gridRowNumber = "dataGrid.rowNumber"
    case gridModified = "dataGrid.modified"
    case gridInserted = "dataGrid.inserted"
    case gridDeleted = "dataGrid.deleted"
    case gridDeletedText = "dataGrid.deletedText"

    /// The group of the file format: the slot's dotted path starts with the group's key.
    public var group: ThemeSlotGroup {
        switch self {
        case .windowBackdrop:
            return .window
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
        }
    }

    /// Where the theme editor lists the slot.
    public var section: ThemeSlotSection {
        switch self {
        case .windowBackdrop:
            return .window
        case .editorBackground, .editorText, .editorCursor, .editorSelection,
             .editorCurrentLine, .editorCurrentStatement, .editorLineNumber, .editorInvisibles:
            return .editor
        case .syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxComment,
             .syntaxNull, .syntaxOperator, .syntaxFunction, .syntaxType:
            return .syntax
        case .gridBackground, .gridText, .gridAlternateRow, .gridHeaderBackground, .gridHeaderText,
             .gridLine, .gridNullValue, .gridBoolTrue, .gridBoolFalse, .gridRowNumber:
            return .dataGrid
        case .gridSelection, .gridSelectionText, .gridInactiveSelection, .gridFocusBorder:
            return .selection
        case .gridModified, .gridInserted, .gridDeleted, .gridDeletedText:
            return .changes
        }
    }

    /// Only the backdrop: content slots keep the theme under Increase Contrast, as they always have.
    public var yieldsToIncreasedContrast: Bool {
        group == .window
    }

    /// Fills that sit under everything else. A translucent window color shows the desktop through the
    /// window, so these never carry alpha.
    public var requiresOpaque: Bool {
        switch self {
        case .windowBackdrop, .editorBackground, .gridBackground, .gridHeaderBackground:
            return true
        case .editorText, .editorCursor, .editorSelection, .editorCurrentLine, .editorCurrentStatement,
             .editorLineNumber, .editorInvisibles,
             .syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxComment,
             .syntaxNull, .syntaxOperator, .syntaxFunction, .syntaxType,
             .gridText, .gridAlternateRow, .gridHeaderText, .gridLine, .gridSelection, .gridSelectionText,
             .gridInactiveSelection, .gridFocusBorder, .gridNullValue, .gridBoolTrue, .gridBoolFalse,
             .gridRowNumber, .gridModified, .gridInserted, .gridDeleted, .gridDeletedText:
            return false
        }
    }

    /// Washes drawn over content, where an alpha channel is the point.
    public var offersOpacity: Bool {
        switch self {
        case .editorSelection, .editorCurrentLine, .editorCurrentStatement, .editorInvisibles,
             .gridAlternateRow, .gridSelection, .gridInactiveSelection,
             .gridModified, .gridInserted, .gridDeleted, .gridDeletedText:
            return true
        case .windowBackdrop, .editorBackground, .editorText, .editorCursor, .editorLineNumber,
             .syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxComment,
             .syntaxNull, .syntaxOperator, .syntaxFunction, .syntaxType,
             .gridBackground, .gridText, .gridHeaderBackground, .gridHeaderText, .gridLine,
             .gridSelectionText, .gridFocusBorder, .gridNullValue, .gridBoolTrue, .gridBoolFalse,
             .gridRowNumber:
            return false
        }
    }

    public var label: String {
        switch self {
        case .windowBackdrop, .editorBackground, .gridBackground: return String(localized: "Background")
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
        }
    }

    /// `label` repeats across groups ("Background" three times), so VoiceOver gets the group too.
    /// Whole phrases, because word order differs between languages.
    public var accessibilityLabel: String {
        switch self {
        case .windowBackdrop: return String(localized: "Window Background")
        case .editorBackground: return String(localized: "Editor Background")
        case .editorText: return String(localized: "Editor Text")
        case .editorCursor: return String(localized: "Editor Cursor")
        case .editorSelection: return String(localized: "Editor Selection")
        case .editorCurrentLine: return String(localized: "Editor Current Line")
        case .editorCurrentStatement: return String(localized: "Editor Current Statement")
        case .editorLineNumber: return String(localized: "Editor Line Number")
        case .editorInvisibles: return String(localized: "Editor Invisibles")
        case .syntaxKeyword: return String(localized: "Syntax Keyword")
        case .syntaxString: return String(localized: "Syntax String")
        case .syntaxNumber: return String(localized: "Syntax Number")
        case .syntaxComment: return String(localized: "Syntax Comment")
        case .syntaxNull: return String(localized: "Syntax NULL")
        case .syntaxOperator: return String(localized: "Syntax Operator")
        case .syntaxFunction: return String(localized: "Syntax Function")
        case .syntaxType: return String(localized: "Syntax Type")
        case .gridBackground: return String(localized: "Data Grid Background")
        case .gridText: return String(localized: "Data Grid Text")
        case .gridAlternateRow: return String(localized: "Data Grid Alternate Row")
        case .gridHeaderBackground: return String(localized: "Data Grid Header Background")
        case .gridHeaderText: return String(localized: "Data Grid Header Text")
        case .gridLine: return String(localized: "Data Grid Line")
        case .gridSelection: return String(localized: "Data Grid Selection")
        case .gridSelectionText: return String(localized: "Data Grid Selected Text")
        case .gridInactiveSelection: return String(localized: "Data Grid Inactive Selection")
        case .gridFocusBorder: return String(localized: "Data Grid Focus Border")
        case .gridNullValue: return String(localized: "Data Grid NULL Value")
        case .gridBoolTrue: return String(localized: "Data Grid Bool True")
        case .gridBoolFalse: return String(localized: "Data Grid Bool False")
        case .gridRowNumber: return String(localized: "Data Grid Row Number")
        case .gridModified: return String(localized: "Data Grid Modified")
        case .gridInserted: return String(localized: "Data Grid Inserted")
        case .gridDeleted: return String(localized: "Data Grid Deleted")
        case .gridDeletedText: return String(localized: "Data Grid Deleted Text")
        }
    }
}
