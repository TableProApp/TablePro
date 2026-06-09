//
//  JSONImportOptionsView.swift
//  JSONImportPlugin
//

import SwiftUI
import TableProPluginKit

struct JSONImportOptionsView: View {
    let plugin: JSONImportPlugin

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
                    : String(localized: "Insert all rows in a single transaction. If any row fails, all changes are rolled back."))

            Toggle("Delete existing rows before import", isOn: Bindable(plugin).settings.deleteExistingRows)
                .font(.system(size: 13))
                .help("Remove every row from the target table before inserting the imported rows.")
        }
    }
}
