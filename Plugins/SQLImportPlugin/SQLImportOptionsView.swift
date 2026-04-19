//
//  SQLImportOptionsView.swift
//  SQLImportPlugin
//

import SwiftUI
import TableProPluginKit

struct SQLImportOptionsView: View {
    let plugin: SQLImportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("On error:", selection: Bindable(plugin).settings.errorHandling) {
                Text("Stop and Rollback").tag(ImportErrorHandling.stopAndRollback)
                Text("Stop and Commit").tag(ImportErrorHandling.stopAndCommit)
                Text("Skip and Continue").tag(ImportErrorHandling.skipAndContinue)
            }
            .pickerStyle(.menu)
            .font(.system(size: 13))

            Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: Bindable(plugin).settings.wrapInTransaction)
                .font(.system(size: 13))
                .disabled(plugin.settings.errorHandling == .skipAndContinue)
                .help(plugin.settings.errorHandling == .skipAndContinue
                    ? String(localized: "Not available in skip-and-continue mode")
                    : String(localized: "Execute all statements in a single transaction. If any statement fails, all changes are rolled back."))

            Toggle("Disable foreign key checks", isOn: Bindable(plugin).settings.disableForeignKeyChecks)
                .font(.system(size: 13))
                .help(
                    "Temporarily disable foreign key constraints during import. Useful for importing data with circular dependencies."
                )
        }
    }
}
