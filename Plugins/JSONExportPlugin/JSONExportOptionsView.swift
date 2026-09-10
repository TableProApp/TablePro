//
//  JSONExportOptionsView.swift
//  JSONExportPlugin
//

import SwiftUI

struct JSONExportOptionsView: View {
    @Bindable var plugin: JSONExportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layout")

                Spacer()

                Picker(String(localized: "Layout", bundle: .main), selection: $plugin.settings.layout) {
                    ForEach(JSONExportLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 180)
            }
            .help("NDJSON writes one row per line with no wrapping array, which a stream reader can process a line at a time")

            Toggle("Pretty print (formatted output)", isOn: $plugin.settings.prettyPrint)
                .toggleStyle(.checkbox)
                .disabled(plugin.settings.layout == .newlineDelimited)

            Toggle("Include NULL values", isOn: $plugin.settings.includeNullValues)
                .toggleStyle(.checkbox)

            Toggle("Preserve all values as strings", isOn: $plugin.settings.preserveAllAsStrings)
                .toggleStyle(.checkbox)
                .help("Keep leading zeros in ZIP codes, phone numbers, and IDs by outputting all values as strings")
        }
        .font(.system(size: 13))
    }
}
