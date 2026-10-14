---
paths:
  - "Packages/TableProEditor/**/*"
  - "TablePro/Theme/**/*"
  - "TablePro/Views/Editor/**/*"
  - "TablePro/Views/RowInspector/**/*"
---

# Editor

- **`ThemeEngine.makeEditorTheme()` builds the `TableProEditorTheme` adapter** the editor draws with. Theme colors and their scope: `.claude/rules/theme.md`.
- **Fonts are not theme.** `TypographySettings` is device-local and stays out of `AppSettingsCategory.synced`: sync replaces a category wholesale, so an older Mac would reset it and each zoom press would push a record.
- **Two font domains.** A view that also wears the editor's colors (the SQL editor, `JSONCodeEditor`, previews) uses `editorFonts`. Every control that shows or edits a stored value uses `ThemeEngine.valueFont` or `valueFontSwiftUI` (the Data Grid Font), so a value reads the same in the grid, the inspector and a popover; a system text style there looks right only while the two settings are equal. `InspectorFieldRow` sets it for the whole inspector, and its `FieldEditorKind` switch is exhaustive on purpose.
- **Multi-cursor lives in `cursorPositions: [CursorPosition]`.**
- **`TableProEditor` is still in Swift 5 language mode** (`.swiftLanguageMode(.v5)`); moving it to Swift 6 is its own change with its own tests.
