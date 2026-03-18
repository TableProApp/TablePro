//
//  SQLExportOptionsView.swift
//  SQLExportPlugin
//

import SwiftUI

struct SQLExportOptionsView: View {
    @Bindable var plugin: SQLExportPlugin

    private static let batchSizeOptions = [1, 100, 500, 1_000]

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

            Toggle("Compress the file using Gzip", isOn: $plugin.settings.compressWithGzip)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
        }
    }
}
