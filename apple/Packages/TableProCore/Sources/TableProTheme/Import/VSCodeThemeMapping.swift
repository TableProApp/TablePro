import Foundation

// The first source a theme answers wins.
internal enum VSCodeColorSource: Equatable, Sendable {
    case color(String)
    // VS Code's own default for the job is this color through `transparent()`.
    case derived(String, alpha: Double)
    // Root scope first, the order a grammar pushes them.
    case token([String])
    case slot(ThemeSlot)
    // What VS Code paints a token no rule colors: `editor.foreground`, or its registry default.
    case defaultTokenForeground
}

// The scope stacks VS Code's own SQL grammar pushes (extensions/sql/syntaxes/sql.tmLanguage.json).
// Function and type take the order of VS Code's token groups instead: the type slot paints every
// table name, and `storage.type` resolves to the keyword color in most themes.
private extension VSCodeColorSource {
    static func sqlToken(_ scope: String) -> VSCodeColorSource {
        .token(["source.sql", scope])
    }
}

internal extension ThemeSlot {
    // A list that stops short leaves the slot to `fallback`, which derives the stripe and the bools the way VS Code paints them.
    var vscodeSources: [VSCodeColorSource] {
        switch self {
        case .windowBackdrop:
            // The region behind the editor. Not the side bar: GitHub Dark's is darker than its editor.
            return [.color("editorPane.background"), .color("editor.background")]
        case .editorBackground:
            return [.color("editor.background")]
        case .editorText:
            return [.color("editor.foreground")]
        case .editorCursor:
            return [.color("editorCursor.foreground")]
        case .editorSelection:
            return [.color("editor.selectionBackground")]
        case .editorCurrentLine:
            // Dracula draws its current line only as a border.
            return [.color("editor.lineHighlightBackground"), .color("editor.lineHighlightBorder")]
        case .editorCurrentStatement:
            // VS Code has no statement band; this is its band for highlighted ranges.
            return [.color("editor.rangeHighlightBackground")]
        case .editorLineNumber:
            return [.color("editorLineNumber.foreground")]
        case .editorInvisibles:
            return [.color("editorWhitespace.foreground")]

        case .syntaxKeyword:
            return [.sqlToken("keyword.other.DML.sql"), .defaultTokenForeground]
        case .syntaxString:
            return [.sqlToken("string.quoted.single.sql"), .defaultTokenForeground]
        case .syntaxNumber:
            return [.sqlToken("constant.numeric.sql"), .defaultTokenForeground]
        case .syntaxComment:
            return [.sqlToken("comment.line.double-dash.sql"), .defaultTokenForeground]
        case .syntaxNull:
            // The SQL grammar scopes NULL as a keyword, and TablePro's defaults draw it in the keyword color.
            return [.sqlToken("constant.language.null.sql"), .slot(.syntaxKeyword)]
        case .syntaxOperator:
            return [.sqlToken("keyword.operator.comparison.sql"), .defaultTokenForeground]
        case .syntaxFunction:
            return [
                .sqlToken("entity.name.function.sql"),
                .sqlToken("support.function.aggregate.sql"),
                .defaultTokenForeground,
            ]
        case .syntaxType:
            return [
                .sqlToken("entity.name.type.sql"),
                .sqlToken("entity.name.class.sql"),
                .sqlToken("support.type.sql"),
                .sqlToken("support.class.sql"),
                .sqlToken("storage.type.sql"),
                .defaultTokenForeground,
            ]

        case .gridBackground:
            return [.color("editor.background")]
        case .gridText:
            return [.color("editor.foreground")]
        case .gridAlternateRow:
            return [.color("keybindingTable.rowsBackground"), .color("tree.tableOddRowsBackground")]
        case .gridHeaderBackground:
            return [.color("keybindingTable.headerBackground"), .color("tree.tableOddRowsBackground")]
        case .gridHeaderText:
            return [.color("foreground")]
        case .gridLine:
            return [.color("tree.tableColumnsBorder")]
        case .gridSelection:
            return [.color("list.activeSelectionBackground")]
        case .gridSelectionText:
            return [.color("list.activeSelectionForeground")]
        case .gridInactiveSelection:
            return [.color("list.inactiveSelectionBackground")]
        case .gridFocusBorder:
            return [.color("list.focusOutline"), .color("focusBorder")]
        case .gridNullValue:
            // The grid draws NULL as placeholder text. `descriptionForeground` equals the text color in
            // One Dark Pro, so NULL would not read as absent.
            return [.color("input.placeholderForeground"), .derived("foreground", alpha: 0.5)]
        case .gridBoolTrue:
            return [.sqlToken("constant.language.boolean.true.sql")]
        case .gridBoolFalse:
            return [.sqlToken("constant.language.boolean.false.sql")]
        case .gridRowNumber:
            return [.color("editorLineNumber.foreground")]
        case .gridModified:
            // VS Code has no modified-row fill, so the theme's modified hue takes the alpha of TablePro's own.
            return [.derived("gitDecoration.modifiedResourceForeground", alpha: 0.3)]
        case .gridInserted:
            return [.color("diffEditor.insertedLineBackground"), .color("diffEditor.insertedTextBackground")]
        case .gridDeleted:
            return [.color("diffEditor.removedLineBackground"), .color("diffEditor.removedTextBackground")]
        case .gridDeletedText:
            // As modified: the hue of a deleted file, the alpha of TablePro's own deleted text.
            return [.derived("gitDecoration.deletedResourceForeground", alpha: 0.5)]
        }
    }
}
