import AppKit

internal enum ThemeAppearance: String, Codable, CaseIterable, Sendable {
    case light
    case dark
}

/// A theme is a set of overrides for the content views and the window backdrop. A slot it leaves out
/// draws in the color AppKit itself uses there, so Default Light and Default Dark declare nothing but
/// syntax colors and render exactly like a native app, following Accent, Highlight and Increase
/// Contrast.
internal struct ThemeDefinition: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var author: String
    var appearance: ThemeAppearance
    var overrides: [ThemeSlot: ThemeColor]

    internal static let builtInPrefix = "tablepro."
    internal static let userPrefix = "user."

    internal var isBuiltIn: Bool { id.hasPrefix(Self.builtInPrefix) }
    internal var isEditable: Bool { !isBuiltIn }

    internal func isOverridden(_ slot: ThemeSlot) -> Bool {
        overrides[slot] != nil
    }

    /// The format has no increased-contrast variant, so a slot that yields to Increase Contrast draws
    /// native in an increased-contrast appearance even where the theme sets it.
    internal func isOverridden(_ slot: ThemeSlot, in appearance: NSAppearance) -> Bool {
        isOverridden(slot, highContrast: appearance.isHighContrast)
    }

    internal func isOverridden(_ slot: ThemeSlot, highContrast: Bool) -> Bool {
        isOverridden(slot) && !(slot.yieldsToIncreasedContrast && highContrast)
    }

    internal func color(for slot: ThemeSlot, in appearance: NSAppearance) -> NSColor {
        guard slot.yieldsToIncreasedContrast, appearance.isHighContrast else { return color(for: slot) }
        return slot.nativeColor
    }

    /// Syntax has no system color, so a syntax slot the theme leaves out takes the same-appearance
    /// default's value, which switches to Xcode's high-contrast palette under Increase Contrast.
    /// Operator falls back to the editor text, overridden or not.
    internal func color(for slot: ThemeSlot) -> NSColor {
        if slot.group == .syntax, BuiltInThemes.isDefault(id) || overrides[slot] == nil,
           let adaptive = BuiltInThemes.adaptiveSyntaxColor(slot, appearance: appearance) {
            return adaptive
        }
        if let override = overrides[slot] {
            return override.nsColor
        }
        if slot == .syntaxOperator {
            return color(for: .editorText)
        }
        return slot.nativeColor
    }
}

/// The single registry every slot goes through. A slot exists here because a call site reads it,
/// which `ThemeSlotCoverageTests` enforces. The document decoder, the encoder and the theme editor
/// all enumerate this list rather than keeping their own copies.
internal enum ThemeSlot: String, CaseIterable, Sendable {
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

    internal var group: ThemeSlotGroup {
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

    /// Only the backdrop: content slots keep the theme under Increase Contrast, as they always have.
    internal var yieldsToIncreasedContrast: Bool {
        group == .window
    }

    internal var label: String {
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
}

internal enum ThemeSlotGroup: String, CaseIterable, Sendable {
    case window
    case editor
    case syntax
    case dataGrid

    internal var label: String {
        switch self {
        case .window: return String(localized: "Window")
        case .editor: return String(localized: "Editor")
        case .syntax: return String(localized: "Syntax")
        case .dataGrid: return String(localized: "Data Grid")
        }
    }

    internal var slots: [ThemeSlot] {
        ThemeSlot.allCases.filter { $0.group == self }
    }
}

internal enum ThemeSchema {
    /// Format 3 dropped the pane and status groups, made every color optional and removed
    /// `system:` values. Format 2 never shipped in a release, and format 1 files carried fonts the
    /// app now keeps in settings.
    internal static let current = 3
}
