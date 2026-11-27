import SwiftUI

internal struct DataSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        DataResultsSettingsView(
            dataGrid: context.settings.dataGridSlice,
            valueColors: context.settings.valueColorsSlice,
            editor: context.settings.editorSlice,
            typography: context.settings.typographySlice,
            history: context.settings.historySlice
        )
    }
}

internal struct DataSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.filters):
            FilterSettingsPage()
        case .page(.queryHistory):
            QueryHistorySettingsPage(history: context.settings.historySlice, context: context)
        case .page(.dataRewind):
            DataRewindPage(history: context.settings.historySlice, context: context)
        default:
            EmptyView()
        }
    }
}

internal struct DataStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
