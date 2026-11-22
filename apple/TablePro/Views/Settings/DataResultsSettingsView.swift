//
//  DataResultsSettingsView.swift
//  TablePro
//

import SwiftUI

struct DataResultsSettingsView: View {
    @Binding var dataGrid: DataGridSettings
    @Binding var valueColors: ValueColorSettings
    @Binding var editor: EditorSettings
    @Binding var typography: TypographySettings

    var body: some View {
        Form {
            TypographySection(domain: .dataGrid, settings: $typography)

            DataGridSection(settings: $dataGrid, valueColors: $valueColors)

            Section("JSON Viewer") {
                Picker("Default view:", selection: $editor.jsonViewerPreferredMode) {
                    Text("Text").tag(JSONViewMode.text)
                    Text("Tree").tag(JSONViewMode.tree)
                }
            }

            Section {
                NavigationLink(value: SettingsSubpage.queryHistory) {
                    Label("Query History", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink(value: SettingsSubpage.dataRewind) {
                    Label("Data Rewind", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    DataResultsSettingsView(
        dataGrid: .constant(.default),
        valueColors: .constant(.default),
        editor: .constant(.default),
        typography: .constant(.default)
    )
    .frame(width: 450, height: 500)
}
