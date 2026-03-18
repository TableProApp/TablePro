//
//  SQLImportOptionsView.swift
//  SQLImportPlugin
//

import SwiftUI

struct SQLImportOptionsView: View {
    let plugin: SQLImportPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: Bindable(plugin).settings.wrapInTransaction)
                .font(.system(size: 13))
                .help(
                    "Execute all statements in a single transaction. If any statement fails, all changes are rolled back."
                )

            Toggle("Disable foreign key checks", isOn: Bindable(plugin).settings.disableForeignKeyChecks)
                .font(.system(size: 13))
                .help(
                    "Temporarily disable foreign key constraints during import. Useful for importing data with circular dependencies."
                )
        }
    }
}
