//
//  DataResultsSettingsView.swift
//  TablePro
//

import SwiftUI

struct DataResultsSettingsView: View {
    @Binding var dataGrid: DataGridSettings
    @Binding var history: HistorySettings
    @Binding var editor: EditorSettings
    @Binding var typography: TypographySettings

    var body: some View {
        Form {
            TypographySection(domain: .dataGrid, settings: $typography)

            DataGridSection(settings: $dataGrid)

            Section("JSON Viewer") {
                Picker("Default view:", selection: $editor.jsonViewerPreferredMode) {
                    Text("Text").tag(JSONViewMode.text)
                    Text("Tree").tag(JSONViewMode.tree)
                }
            }

            HistorySection(settings: $history)

            DataRewindSection(settings: $history)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    DataResultsSettingsView(
        dataGrid: .constant(.default),
        history: .constant(.default),
        editor: .constant(.default),
        typography: .constant(.default)
    )
    .frame(width: 450, height: 500)
}
