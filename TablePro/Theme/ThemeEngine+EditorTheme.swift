import AppKit
import TableProEditorKit

internal extension ThemeEngine {
    /// A slot the theme leaves out arrives as the system color object itself, which the editor resolves when it draws.
    /// An Accent, Highlight or contrast change therefore builds an equal `EditorTheme`, and the editor keeps its
    /// highlighting rather than restyling the whole document.
    func makeEditorTheme() -> EditorTheme {
        let editorSettings = AppSettingsManager.shared.editor
        let text = EditorTheme.Attribute(color: resolved[.editorText])
        let comment = EditorTheme.Attribute(color: resolved[.syntaxComment])
        let keyword = EditorTheme.Attribute(color: resolved[.syntaxKeyword], bold: true)
        let string = EditorTheme.Attribute(color: resolved[.syntaxString])
        let number = EditorTheme.Attribute(color: resolved[.syntaxNumber])
        let variable = EditorTheme.Attribute(color: resolved[.syntaxNull])
        let type = EditorTheme.Attribute(color: resolved[.syntaxType])
        let operatorAttribute = EditorTheme.Attribute(color: resolved[.syntaxOperator])
        let function = EditorTheme.Attribute(color: resolved[.syntaxFunction])

        return EditorTheme(
            text: text,
            insertionPoint: resolved.isOverridden(.editorCursor) ? resolved[.editorCursor] : nil,
            invisibles: EditorTheme.Attribute(color: resolved[.editorInvisibles]),
            background: resolved[.editorBackground],
            lineHighlight: editorSettings.highlightCurrentLine ? resolved[.editorCurrentLine] : .clear,
            statementHighlight: editorSettings.highlightCurrentStatement ? resolved[.editorCurrentStatement] : .clear,
            selection: resolved[.editorSelection],
            lineNumber: resolved[.editorLineNumber],
            keywords: keyword,
            commands: keyword,
            types: type,
            attributes: variable,
            variables: variable,
            values: variable,
            numbers: number,
            strings: string,
            characters: string,
            comments: comment,
            operators: operatorAttribute,
            functions: function
        )
    }
}
