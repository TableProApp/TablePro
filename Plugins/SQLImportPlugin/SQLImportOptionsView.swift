//
//  SQLImportOptionsView.swift
//  SQLImportPlugin
//

import SwiftUI
import TableProPluginKit

struct SQLImportOptionsView: View {
    @ObservedObject var plugin: SQLImportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("On error:", selection: $plugin.settings.errorHandling) {
                Text("Stop and Rollback").tag(ImportErrorHandling.stopAndRollback)
                Text("Stop and Commit").tag(ImportErrorHandling.stopAndCommit)
                Text("Skip and Continue").tag(ImportErrorHandling.skipAndContinue)
            }
            .pickerStyle(.menu)
            .font(.system(size: 13))

            Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: $plugin.settings.wrapInTransaction)
                .font(.system(size: 13))
                .disabled(plugin.settings.errorHandling == .skipAndContinue)
                .help(plugin.settings.errorHandling == .skipAndContinue
                    ? String(localized: "Not available in skip-and-continue mode")
                    : String(
                        localized: "Runs every statement in one transaction, so a failure rolls back what the import changed. A database that commits CREATE, ALTER and DROP as they run, such as MySQL, keeps those statements and everything before them."
                    ))

            Toggle("Disable foreign key checks", isOn: $plugin.settings.disableForeignKeyChecks)
                .font(.system(size: 13))
                .help(
                    "Temporarily disable foreign key constraints during import. Useful for importing data with circular dependencies."
                )
        }
    }
}
