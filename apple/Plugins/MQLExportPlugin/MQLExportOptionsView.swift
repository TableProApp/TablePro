//
//  MQLExportOptionsView.swift
//  MQLExportPlugin
//

import SwiftUI

struct MQLExportOptionsView: View {
    @ObservedObject var plugin: MQLExportPlugin

    private static let batchSizeOptions = [100, 500, 1_000, 5_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exports data as mongosh-compatible scripts. Drop, Indexes, and Data options are configured per collection in the collection list.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            HStack {
                Text("Rows per batch")
                    .font(.system(size: 13))

                Spacer()

                Picker(String(localized: "Rows per batch", bundle: .main), selection: $plugin.settings.batchSize) {
                    ForEach(Self.batchSizeOptions, id: \.self) { size in
                        Text("\(size)")
                            .tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }
            .help(String(localized: "Maximum documents per batch. Large documents use smaller batches to fit the server limit.", bundle: .main))
        }
    }
}
