//
//  DataGridSettingsView.swift
//  TablePro
//
//  Settings for data grid display and pagination (fonts moved to theme)
//

import SwiftUI

struct DataGridSettingsView: View {
    @Binding var settings: DataGridSettings

    var body: some View {
        Form {
            Section("Display") {
                Picker("Row height:", selection: $settings.rowHeight) {
                    ForEach(DataGridRowHeight.allCases) { height in
                        Text(height.displayName).tag(height)
                    }
                }

                Picker("Date format:", selection: $settings.dateFormat) {
                    ForEach(DateFormatOption.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    TextField("NULL display:", text: $settings.nullDisplay)

                    if let error = settings.nullDisplayValidationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Max \(SettingsValidationRules.nullDisplayMaxLength) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Show alternate row backgrounds", isOn: $settings.showAlternateRows)

                Toggle("Show row numbers", isOn: $settings.showRowNumbers)

                Toggle("Auto-show inspector on row select", isOn: $settings.autoShowInspector)
            }

            Section("Pagination") {
                Picker("Default page size:", selection: $settings.defaultPageSize) {
                    Text("100 rows").tag(100)
                    Text("500 rows").tag(500)
                    Text("1,000 rows").tag(1_000)
                    Text("5,000 rows").tag(5_000)
                    Text("10,000 rows").tag(10_000)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    DataGridSettingsView(settings: .constant(.default))
        .frame(width: 450, height: 350)
}
