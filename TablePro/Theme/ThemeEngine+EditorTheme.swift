import AppKit
import TableProEditorKit

internal extension ThemeEngine {
    func makeEditorTheme() -> EditorTheme {
        let editorSettings = AppSettingsManager.shared.editor
        return EditorThemeFactory.make(
            resolved: resolved,
            highlightsCurrentLine: editorSettings.highlightCurrentLine,
            highlightsCurrentStatement: editorSettings.highlightCurrentStatement
        )
    }
}
