//
//  XLSXImportOptionsView.swift
//  XLSXImportPlugin
//

import SwiftUI
import TableProPluginKit

struct XLSXImportOptionsView: View {
    @Bindable var plugin: XLSXImportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("First row holds column names", isOn: $plugin.settings.hasHeaderRow)
                .toggleStyle(.checkbox)
                .help("Off names the columns column1, column2 and so on")

            Toggle("Trim whitespace", isOn: $plugin.settings.trimWhitespace)
                .toggleStyle(.checkbox)

            Toggle("Treat empty cells as NULL", isOn: $plugin.settings.emptyAsNull)
                .toggleStyle(.checkbox)

            Picker("On error", selection: $plugin.settings.errorHandling) {
                Text("Stop and Rollback").tag(ImportErrorHandling.stopAndRollback)
                Text("Stop and Commit").tag(ImportErrorHandling.stopAndCommit)
                Text("Skip and Continue").tag(ImportErrorHandling.skipAndContinue)
            }

            Toggle("Wrap in transaction", isOn: $plugin.settings.wrapInTransaction)
                .toggleStyle(.checkbox)
                .disabled(plugin.settings.errorHandling == .skipAndContinue)

            Toggle("Delete existing rows first", isOn: $plugin.settings.deleteExistingRows)
                .toggleStyle(.checkbox)
        }
        .font(.system(size: 13))
    }
}
