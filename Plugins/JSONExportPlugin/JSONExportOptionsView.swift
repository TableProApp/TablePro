//
//  JSONExportOptionsView.swift
//  JSONExportPlugin
//

import SwiftUI

struct JSONExportOptionsView: View {
    @Bindable var plugin: JSONExportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Pretty print (formatted output)", isOn: $plugin.settings.prettyPrint)
                .toggleStyle(.checkbox)

            Toggle("Include NULL values", isOn: $plugin.settings.includeNullValues)
                .toggleStyle(.checkbox)

            Toggle("Preserve all values as strings", isOn: $plugin.settings.preserveAllAsStrings)
                .toggleStyle(.checkbox)
                .help("Keep leading zeros in ZIP codes, phone numbers, and IDs by outputting all values as strings")
        }
        .font(.system(size: 13))
    }
}
