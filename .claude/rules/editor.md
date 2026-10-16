---
paths:
  - "Packages/TableProEditor/**/*"
  - "TablePro/Theme/**/*"
  - "TablePro/Views/Editor/**/*"
  - "TablePro/Views/RowInspector/**/*"
---

# Editor

- **`EditorThemeFactory` builds the `EditorTheme` the editor draws with.** `make(resolved:highlightsCurrentLine:highlightsCurrentStatement:)` is pure over a `ResolvedTheme`. `ThemeEngine.makeEditorTheme()` and `TableProEditorTheme.make()` call it with the live theme and the editor settings; the theme editor preview calls it with a fixed scope's `resolved`. Theme colors and their scope: `.claude/rules/theme.md`.
- **Aliases and parameters take `editor.text`.** The `variables` capture (aliases, parameters, properties) is a name the user wrote, so it draws in the text color; `attributes` and `values` keep `editor.syntax.null`. Keywords draw bold.
- **A static code view highlights like the editor.** `HighlightedSQLTextView` and chat code blocks color `CodeBlockHighlighter.captures(in:language:)`, the editor's grammar, through the same `EditorTheme`, so a statement reads the same in a preview, a chat block and the editor. Only whole lines before its 10k-character cap get colors. Never add a second highlighter.
- **Fonts are not theme.** `TypographySettings` is device-local and stays out of `AppSettingsCategory.synced`: sync replaces a category wholesale, so an older Mac would reset it and each zoom press would push a record.
- **Two font domains.** A view that also wears the editor's colors (the SQL editor, `JSONCodeEditor`, previews) uses `editorFonts`. Every control that shows or edits a stored value uses `ThemeEngine.valueFont` or `valueFontSwiftUI` (the Data Grid Font), so a value reads the same in the grid, the inspector and a popover; a system text style there looks right only while the two settings are equal. `InspectorFieldRow` sets it for the whole inspector, and its `FieldEditorKind` switch is exhaustive on purpose.
- **Multi-cursor lives in `cursorPositions: [CursorPosition]`.**
- **`TableProEditor` is still in Swift 5 language mode** (`.swiftLanguageMode(.v5)`); moving it to Swift 6 is its own change with its own tests.
