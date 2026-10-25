import Foundation

public enum ThemeSlotFallback: Equatable, Sendable {
    case system
    // Syntax has no system color, so it takes the same-appearance default's.
    case defaultSyntax
    // The other slot's theme color, else the slot's native color.
    case slot(ThemeSlot)
    // Built from `base` while the theme sets it, else the slot's native color.
    case derived(base: ThemeSlot, rule: ThemeDerivationRule)
}

public enum ThemeDerivationRule: Equatable, Sendable {
    // Toward `toward`'s theme color, else toward black in a light theme and white in a dark one.
    case stripe(toward: ThemeSlot)

    // AppKit's alternate stripe sits about 4% from its row background in both appearances.
    public static let stripeFraction = 0.04
}

public extension ThemeSlot {
    // A rule only names slots that fall back to the system themselves, so resolution never chains.
    var fallback: ThemeSlotFallback {
        switch self {
        case .windowBackdrop,
             .editorBackground, .editorText, .editorCursor, .editorSelection,
             .editorCurrentLine, .editorCurrentStatement, .editorLineNumber, .editorInvisibles,
             .gridBackground, .gridText, .gridLine,
             .gridNullValue, .gridRowNumber, .gridModified, .gridInserted, .gridDeleted, .gridDeletedText:
            return .system
        case .syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxComment,
             .syntaxNull, .syntaxFunction, .syntaxType:
            return .defaultSyntax
        case .syntaxOperator:
            return .slot(.editorText)
        // A bool in labelColor next to themed cell text reads as a different table.
        case .gridBoolTrue, .gridBoolFalse:
            return .slot(.gridText)
        case .gridAlternateRow:
            return .derived(base: .gridBackground, rule: .stripe(toward: .gridText))
        }
    }
}
