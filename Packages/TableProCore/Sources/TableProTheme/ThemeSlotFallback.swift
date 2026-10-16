import Foundation

/// What a slot draws when the theme leaves it out.
public enum ThemeSlotFallback: Equatable, Sendable {
    /// The slot's native color.
    case system
    /// The same-appearance default's syntax color: syntax has no system color.
    case defaultSyntax
    /// The other slot's theme color, else the slot's native color.
    case slot(ThemeSlot)
    /// Built from `base` while the theme sets it, else the slot's native color.
    case derived(base: ThemeSlot, rule: ThemeDerivationRule)
    /// Only while the theme sets `with`: the slot's own color, else `fallback`'s value. Otherwise the
    /// slot's native color, whatever the theme sets.
    case paired(with: ThemeSlot, fallback: ThemeSlot)
}

public enum ThemeDerivationRule: Equatable, Sendable {
    /// The base moved `stripeFraction` toward `toward`'s theme color, or toward black in a light theme
    /// and white in a dark one.
    case stripe(toward: ThemeSlot)
    /// The base itself.
    case same

    /// AppKit's alternate stripe sits about 4% from its row background in both appearances.
    public static let stripeFraction = 0.04
}

public extension ThemeSlot {
    /// Exhaustive, so a new slot cannot ship without a rule. A rule only names slots that fall back to
    /// the system themselves, so resolution never chains.
    var fallback: ThemeSlotFallback {
        switch self {
        case .windowBackdrop,
             .editorBackground, .editorText, .editorCursor, .editorSelection,
             .editorCurrentLine, .editorCurrentStatement, .editorLineNumber, .editorInvisibles,
             .gridBackground, .gridText, .gridLine, .gridSelection, .gridInactiveSelection, .gridFocusBorder,
             .gridNullValue, .gridRowNumber, .gridModified, .gridInserted, .gridDeleted, .gridDeletedText:
            return .system
        case .syntaxKeyword, .syntaxString, .syntaxNumber, .syntaxComment,
             .syntaxNull, .syntaxFunction, .syntaxType:
            return .defaultSyntax
        case .syntaxOperator:
            return .slot(.editorText)
        // A bool or a header label in labelColor next to themed cell text reads as a different table.
        case .gridBoolTrue, .gridBoolFalse, .gridHeaderText:
            return .slot(.gridText)
        case .gridAlternateRow:
            return .derived(base: .gridBackground, rule: .stripe(toward: .gridText))
        // Natively the header and the rows share controlBackgroundColor.
        case .gridHeaderBackground:
            return .derived(base: .gridBackground, rule: .same)
        // AppKit's own selection keeps its white text, so a theme's selection text only means
        // something over the theme's selection.
        case .gridSelectionText:
            return .paired(with: .gridSelection, fallback: .gridText)
        }
    }
}
