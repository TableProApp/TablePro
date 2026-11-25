//
//  SQLImportOptionsView.swift
//  SQLImportPlugin
//

import SwiftUI
import TableProPluginKit

struct SQLImportOptionsView: View {
    @ObservedObject var plugin: SQLImportPlugin

    // Flat rows, so the host's Form lines them up with its own; a VStack would make them one row.
    var body: some View {
        Picker("On error:", selection: $plugin.settings.errorHandling) {
            Text("Stop and Rollback").tag(ImportErrorHandling.stopAndRollback)
            Text("Stop and Commit").tag(ImportErrorHandling.stopAndCommit)
            Text("Skip and Continue").tag(ImportErrorHandling.skipAndContinue)
        }
        .pickerStyle(.menu)

        Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: $plugin.settings.wrapInTransaction)
            .disabled(plugin.settings.errorHandling == .skipAndContinue)
            .help(plugin.settings.errorHandling == .skipAndContinue
                ? String(localized: "Not available in skip-and-continue mode")
                : String(
                    localized: "Runs every statement in one transaction, so a failure rolls back what the import changed. A database that commits CREATE, ALTER and DROP as they run, such as MySQL, keeps those statements and everything before them."
                ))

        Toggle("Disable foreign key checks", isOn: $plugin.settings.disableForeignKeyChecks)
            .help(
                "Temporarily disable foreign key constraints during import. Useful for importing data with circular dependencies."
            )
    }
}

extension SQLImportPlugin {
    @MainActor
    func settingsView() -> AnyView? {
        AnyView(SQLImportOptionsView(plugin: self))
    }
}
