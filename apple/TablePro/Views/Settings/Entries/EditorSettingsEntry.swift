import SwiftUI

internal struct EditorSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var editor: SettingsSlice<EditorSettings>
    @ObservedObject private var typography: SettingsSlice<TypographySettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._editor = ObservedObject(wrappedValue: context.settings.editorSlice)
        self._typography = ObservedObject(wrappedValue: context.settings.typographySlice)
    }

    internal var body: some View {
        EditorSettingsView(settings: $editor.value, typography: $typography.value)
    }
}

internal struct EditorSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext
    @ObservedObject private var formatter: SettingsSlice<SQLFormatterSettings>
    @ObservedObject private var editor: SettingsSlice<EditorSettings>

    internal init(route: SettingsRoute, context: SettingsPaneContext) {
        self.route = route
        self.context = context
        self._formatter = ObservedObject(wrappedValue: context.settings.formatterSlice)
        self._editor = ObservedObject(wrappedValue: context.settings.editorSlice)
    }

    internal var body: some View {
        switch route {
        case .page(.sqlFormatting):
            Form { FormatterSection(settings: $formatter.value, editor: editor.value) }
                .formStyle(.grouped)
        default:
            SettingsPagePlaceholder(title: context.navigation.title(for: route))
        }
    }
}

internal struct EditorStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
