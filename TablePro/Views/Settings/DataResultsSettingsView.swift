//
//  DataResultsSettingsView.swift
//  TablePro
//

import SwiftUI

struct DataResultsSettingsView: View {
    @Binding var dataGrid: DataGridSettings
    @Binding var history: HistorySettings
    @Binding var editor: EditorSettings

    var body: some View {
        Form {
            DataGridSection(settings: $dataGrid)

            Section("JSON Viewer") {
                Picker("Default view:", selection: $editor.jsonViewerPreferredMode) {
                    Text("Text").tag(JSONViewMode.text)
                    Text("Tree").tag(JSONViewMode.tree)
                }
            }

            HistorySection(settings: $history)

            SavedCustomizationsSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    DataResultsSettingsView(
        dataGrid: .constant(.default),
        history: .constant(.default),
        editor: .constant(.default)
    )
    .frame(width: 450, height: 500)
}
