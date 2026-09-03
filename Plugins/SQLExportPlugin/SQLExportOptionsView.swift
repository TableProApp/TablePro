//
//  SQLExportOptionsView.swift
//  SQLExportPlugin
//

import SwiftUI

struct SQLExportOptionsView: View {
    @Bindable var plugin: SQLExportPlugin

    private static let batchSizeOptions = [1, 100, 500, 1_000]

    private static let splitSizeOptions = [0, 8, 32, 128, 512]

    private static let insertModeHelp = String(
        localized: """
            What an INSERT does when the row already exists. MySQL, MariaDB, PostgreSQL and SQLite \
            each spell this differently; an engine with no spelling for it writes plain inserts and \
            the summary says so.
            """,
        bundle: .main
    )

    private static let snapshotHelp = String(
        localized: """
            Reads every table inside one transaction, so a dump of several tables is consistent with \
            itself. The transaction stays open for the whole export.
            """,
        bundle: .main
    )

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

            HStack {
                Text("On existing rows")
                    .font(.system(size: 13))

                Spacer()

                Picker("", selection: $plugin.settings.insertMode) {
                    ForEach(SQLExportInsertMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
            }
            .help(Self.insertModeHelp)

            HStack {
                Text("Split every")
                    .font(.system(size: 13))

                Spacer()

                Picker("", selection: $plugin.settings.splitSizeMegabytes) {
                    ForEach(Self.splitSizeOptions, id: \.self) { size in
                        Text(size == 0 ? String(localized: "One file", bundle: .main) : "\(size) MB")
                            .tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }
            .help("Writes .part1, .part2 and so on once the file passes this size")

            Toggle("Read every table at one snapshot", isOn: $plugin.settings.consistentSnapshot)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .help(Self.snapshotHelp)

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
