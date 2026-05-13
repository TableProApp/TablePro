//
//  DataGridSection.swift
//  TablePro
//

import SwiftUI

struct DataGridSection: View {
    @Binding var settings: DataGridSettings

    var body: some View {
        Section("Data Grid") {
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
                    .help("Max \(SettingsValidationRules.nullDisplayMaxLength) characters")

                if let error = settings.nullDisplayValidationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }

            Toggle("Show alternate row backgrounds", isOn: $settings.showAlternateRows)
            Toggle("Show row numbers", isOn: $settings.showRowNumbers)
            Toggle("Auto-show inspector on row select", isOn: $settings.autoShowInspector)
            Toggle("Smart value detection", isOn: $settings.enableSmartValueDetection)
        }

        Section("Pagination") {
            Picker("Default page size:", selection: $settings.defaultPageSize) {
                Text("100 rows").tag(100)
                Text("500 rows").tag(500)
                Text("1,000 rows").tag(1_000)
                Text("5,000 rows").tag(5_000)
                Text("10,000 rows").tag(10_000)
            }

            Picker(
                String(localized: "Count rows if estimate less than:"),
                selection: $settings.countRowsIfEstimateLessThan
            ) {
                Text("1,000").tag(1_000)
                Text("10,000").tag(10_000)
                Text("100,000").tag(100_000)
                Text("1,000,000").tag(1_000_000)
                Text(String(localized: "Always count")).tag(Int.max)
            }
            .help(String(localized: "Tables with more estimated rows use approximate counts to avoid slow COUNT(*) queries"))
        }

        Section {
            Toggle("Truncate query results", isOn: $settings.truncateQueryResults)
                .help(String(localized: "Cap user query results at the configured row count"))

            if settings.truncateQueryResults {
                Picker("Row cap:", selection: $settings.queryResultRowCap) {
                    Text("100").tag(100)
                    Text("1,000").tag(1_000)
                    Text("5,000").tag(5_000)
                    Text("10,000").tag(10_000)
                    Text("50,000").tag(50_000)
                    Text("100,000").tag(100_000)
                    Text("500,000").tag(500_000)
                }

                if let error = settings.queryResultRowCapValidationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }
        } header: {
            Text("Query Result Row Cap")
        } footer: {
            if settings.truncateQueryResults, settings.queryResultRowCapValidationError == nil {
                Text("Capped results show a Fetch All button to load the full set")
            }
        }
    }
}
