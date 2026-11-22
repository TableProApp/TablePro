import Combine
import SwiftUI

internal struct EditorSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        EditorSettingsView(editor: context.settings.editorSlice, typography: context.settings.typographySlice)
    }
}

internal struct EditorSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.sqlFormatting):
            SQLFormattingPageHost(formatter: context.settings.formatterSlice, editor: context.settings.editorSlice)
        default:
            EmptyView()
        }
    }
}

internal struct EditorStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}

// Follows only the editor font, so a theme change elsewhere never re-renders the page.
private struct SQLFormattingPageHost: View {
    @ObservedObject var formatter: SettingsSlice<SQLFormatterSettings>
    @ObservedObject var editor: SettingsSlice<EditorSettings>
    @State private var font = ThemeEngine.shared.editorFonts.font

    var body: some View {
        SQLFormattingPage(settings: $formatter.value, editor: editor.value, font: font)
            .onReceive(ThemeEngine.shared.$editorFonts.map(\.font).removeDuplicates()) { font = $0 }
    }
}
