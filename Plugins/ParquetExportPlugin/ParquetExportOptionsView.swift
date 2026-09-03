//
//  ParquetExportOptionsView.swift
//  ParquetExportPlugin
//

import SwiftUI

struct ParquetExportOptionsView: View {
    @Bindable var plugin: ParquetExportPlugin

    private static let rowGroupSizes = [10_000, 50_000, 122_880, 500_000, 1_000_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Compression")
                Spacer()
                Picker("", selection: $plugin.settings.compression) {
                    ForEach(ParquetCompression.allCases) { compression in
                        Text(compression.label).tag(compression)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }
            .help("Snappy is what every Parquet reader supports. Zstd is smaller and needs a reader built with it")

            HStack {
                Text("Rows per group")
                Spacer()
                Picker("", selection: $plugin.settings.rowGroupSize) {
                    ForEach(Self.rowGroupSizes, id: \.self) { size in
                        Text(size.formatted()).tag(size)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
            }
            .help("Larger groups compress better and cost more memory to read")

            Text("Parquet holds one table per file. A multi-table export writes one file each.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
    }
}
