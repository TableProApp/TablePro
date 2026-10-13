---
paths:
  - "Packages/TableProEditor/**/*"
  - "TablePro/Theme/**/*"
  - "TablePro/Views/Editor/**/*"
  - "TablePro/Views/RowInspector/**/*"
---

# Editor and theme

- **`ThemeEngine` is the single source of theme colors**; `ThemeEngine.makeEditorTheme()` builds the `TableProEditorTheme` adapter.
- **A theme colors two surfaces: code views and the data grid.** Code views are the SQL editor and every other `SourceEditor` or SQL text view (JSON editor, DDL, trigger, previews, AI code blocks, history). Every other pane, Settings and all chrome use semantic system colors directly and never read the theme. `NSApp.appearance` is the only lever on chrome.
- **A slot exists only with a reader.** `ThemeSlot` is the one registry the decoder, encoder and theme editor enumerate, and `ThemeSlotCoverageTests` fails a slot nothing reads. Every slot is optional: a theme that leaves one out draws `ThemeSlot.nativeColor`, the color AppKit itself uses there. Default Light and Default Dark override syntax only, with Xcode's Default values.
- **Two color tiers.** `palette[slot]` is a dynamic color over the live theme pair; use it wherever a view holds a color. `resolved[slot]` is the active theme's override or the system color object itself, never a flattened copy; turn it into a `CGColor` only inside the drawing view's appearance (`resolved.cgColor(_:in:)`), and check `resolved.isOverridden(_:)` before replacing a native drawing path (row selection, caret, header). Never call `withAlphaComponent` on a system color outside an `NSColor(name:dynamicProvider:)`: it freezes the color.
- **A theme change has to reach the view.** `AppEvents.shared.themeChanged` fires on a theme change, a light/dark flip, an Accent or Highlight change and an Increase Contrast toggle. A SwiftUI view that reads the engine observes it (`@ObservedObject private var themeEngine = ThemeEngine.shared`), because SwiftUI caches `Color(nsColor:)` by object identity; an AppKit view that bakes a color subscribes to `themeChanged` and re-bakes.
- **Fonts are not theme.** `TypographySettings` is device-local and stays out of `AppSettingsCategory.synced`: sync replaces a category wholesale, so an older Mac would reset it and each zoom press would push a record.
- **Two font domains.** A view that also wears the editor's colors (the SQL editor, `JSONCodeEditor`, previews) uses `editorFonts`. Every control that shows or edits a stored value uses `ThemeEngine.valueFont` or `valueFontSwiftUI` (the Data Grid Font), so a value reads the same in the grid, the inspector and a popover; a system text style there looks right only while the two settings are equal. `InspectorFieldRow` sets it for the whole inspector, and its `FieldEditorKind` switch is exhaustive on purpose.
- **Multi-cursor lives in `cursorPositions: [CursorPosition]`.**
- **`TableProEditor` is still in Swift 5 language mode** (`.swiftLanguageMode(.v5)`); moving it to Swift 6 is its own change with its own tests.
