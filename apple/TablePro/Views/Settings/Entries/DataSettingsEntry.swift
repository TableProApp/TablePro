import SwiftUI

internal struct DataSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var dataGrid: SettingsSlice<DataGridSettings>
    @ObservedObject private var valueColors: SettingsSlice<ValueColorSettings>
    @ObservedObject private var editor: SettingsSlice<EditorSettings>
    @ObservedObject private var typography: SettingsSlice<TypographySettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._dataGrid = ObservedObject(wrappedValue: context.settings.dataGridSlice)
        self._valueColors = ObservedObject(wrappedValue: context.settings.valueColorsSlice)
        self._editor = ObservedObject(wrappedValue: context.settings.editorSlice)
        self._typography = ObservedObject(wrappedValue: context.settings.typographySlice)
    }

    internal var body: some View {
        DataResultsSettingsView(
            dataGrid: $dataGrid.value,
            valueColors: $valueColors.value,
            editor: $editor.value,
            typography: $typography.value
        )
    }
}

internal struct DataSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext
    @ObservedObject private var history: SettingsSlice<HistorySettings>

    internal init(route: SettingsRoute, context: SettingsPaneContext) {
        self.route = route
        self.context = context
        self._history = ObservedObject(wrappedValue: context.settings.historySlice)
    }

    internal var body: some View {
        switch route {
        case .page(.queryHistory):
            Form { HistorySection(settings: $history.value) }
                .formStyle(.grouped)
        case .page(.dataRewind):
            Form { DataRewindSection(settings: $history.value) }
                .formStyle(.grouped)
        default:
            SettingsPagePlaceholder(title: context.navigation.title(for: route))
        }
    }
}

internal struct DataStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
