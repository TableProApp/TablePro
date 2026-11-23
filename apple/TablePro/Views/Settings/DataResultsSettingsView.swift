import SwiftUI

struct DataResultsSettingsView: View {
    @ObservedObject var dataGrid: SettingsSlice<DataGridSettings>
    let valueColors: SettingsSlice<ValueColorSettings>
    let editor: SettingsSlice<EditorSettings>
    let typography: SettingsSlice<TypographySettings>
    let history: SettingsSlice<HistorySettings>

    var body: some View {
        Form {
            DataGridSection(
                settings: $dataGrid.value,
                typography: typography,
                valueColors: valueColors,
                editor: editor
            )

            FilterSettingsSection()

            Section {
                // No value: Keep entries for also bounds query tab versions, so one word would mislead.
                SettingsDrillRow(route: SettingsRoute.page(.queryHistory), title: SettingsPage.queryHistory.title)
                DataRewindDrillRow(history: history)
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-data")
    }
}
