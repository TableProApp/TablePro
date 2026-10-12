---
paths:
  - "Packages/TableProEditor/**/*"
  - "TablePro/Theme/**/*"
  - "TablePro/Views/Editor/**/*"
  - "TablePro/Views/RowInspector/**/*"
---

# Editor and theme

- **`ThemeEngine` is the single source of theme colors**; `ThemeEngine.makeEditorTheme()` builds the `TableProEditorTheme` adapter.
- **A slot exists only with a reader.** `ThemeSlot` is the one registry the gate, the theme editor and the decoder enumerate, and `ThemeSlotCoverageTests` fails a slot nothing reads. A theme file must declare every slot of its schema, as `#hex` or `system:<name>`.
- **Two color tiers.** `palette[slot]` is a dynamic color that answers for the theme in effect; use it wherever a view holds a color. `resolved[slot]` is a snapshot for code that bakes one (`CALayer`, the editor theme, the grid's cell drawing), paired with an `AppEvents.shared.themeChanged` subscription.
- **A theme change has to reach the view.** A SwiftUI view that reads the engine observes it (`@ObservedObject private var themeEngine = ThemeEngine.shared`), because SwiftUI caches `Color(nsColor:)` by object identity; an AppKit view subscribes to `themeChanged` and redisplays.
- **A theme colors content, never chrome.** `NSApp.appearance` is the only lever on the sidebar, the trailing pane, the editor tab strip and the window background: a theme declares `light` or `dark` and the frame follows. Painting them means covering views AppKit owns (the sidebar's `NSGlassEffectView`, the titlebar band, the source-list selection), so every slot is namespaced `content.` and none is added for chrome.
- **Fonts are not theme.** `TypographySettings` is device-local and stays out of `AppSettingsCategory.synced`: sync replaces a category wholesale, so an older Mac would reset it and each zoom press would push a record.
- **Two font domains.** A view that also wears the editor's colors (the SQL editor, `JSONCodeEditor`, previews) uses `editorFonts`. Every control that shows or edits a stored value uses `ThemeEngine.valueFont` or `valueFontSwiftUI` (the Data Grid Font), so a value reads the same in the grid, the inspector and a popover; a system text style there looks right only while the two settings are equal. `InspectorFieldRow` sets it for the whole inspector, and its `FieldEditorKind` switch is exhaustive on purpose.
- **Multi-cursor lives in `cursorPositions: [CursorPosition]`.**
- **`TableProEditor` is still in Swift 5 language mode** (`.swiftLanguageMode(.v5)`); moving it to Swift 6 is its own change with its own tests.
