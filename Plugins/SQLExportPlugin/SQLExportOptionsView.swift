//
//  SQLExportOptionsView.swift
//  SQLExportPlugin
//

import SwiftUI

struct SQLExportOptionsView: View {
    @Bindable var plugin: SQLExportPlugin

    private static let batchSizeOptions = [1, 100, 500, 1_000]

    private static let autoIncrementHelp = String(
        localized: "MySQL and MariaDB. Drops the table's next key value. The column keeps its AUTO_INCREMENT attribute, and restoring rows sets the counter from the data.",
        bundle: .main
    )

    private static let definerHelp = String(
        localized: """
            MySQL and MariaDB. Drops the account a view was created under. The importing account \
            becomes the definer, so the view runs with its privileges. An account the target server \
            does not have makes the import fail.
            """,
        bundle: .main
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Structure, Drop, and Data options are configured per table in the table list.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            HStack {
                Text("Rows per INSERT")
                    .font(.system(size: 13))

                Spacer()

                Picker("", selection: $plugin.settings.batchSize) {
                    ForEach(Self.batchSizeOptions, id: \.self) { size in
                        Text(size == 1 ? String(localized: "1 (no batching)", bundle: .main) : "\(size)")
                            .tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }
            .help("Higher values create fewer INSERT statements, resulting in smaller files and faster imports")

            Toggle("Exclude the AUTO_INCREMENT counter", isOn: $plugin.settings.excludeAutoIncrementValue)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .help(Self.autoIncrementHelp)

            Toggle("Exclude DEFINER clauses", isOn: $plugin.settings.excludeDefiner)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .help(Self.definerHelp)

            Toggle("Compress the file using Gzip", isOn: $plugin.settings.compressWithGzip)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
        }
    }
}
