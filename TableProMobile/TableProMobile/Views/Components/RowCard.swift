//
//  RowCard.swift
//  TableProMobile
//

import SwiftUI
import TableProModels

struct RowCard: View {
    let columns: [ColumnInfo]
    let columnDetails: [ColumnInfo]
    let row: [String?]

    private static let maxPreview = 4

    private var pkNames: Set<String> {
        Set(columnDetails.filter(\.isPrimaryKey).map(\.name))
    }

    private var titlePair: (name: String, value: String)? {
        let pks = pkNames
        for (col, val) in zip(columns, row) where pks.contains(col.name) {
            return (col.name, val ?? "NULL")
        }
        guard let first = columns.first else { return nil }
        return (first.name, row.first.flatMap { $0 } ?? "NULL")
    }

    private var detailPairs: [(name: String, value: String)] {
        let pks = pkNames
        let title = titlePair?.name
        return zip(columns, row)
            .filter { !pks.contains($0.0.name) && $0.0.name != title }
            .prefix(Self.maxPreview - 1)
            .map { ($0.0.name, $0.1 ?? "NULL") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = titlePair {
                HStack(spacing: 6) {
                    Text(title.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: title.value)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
            }

            ForEach(Array(detailPairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 6) {
                    Text(pair.name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: pair.value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if columns.count > Self.maxPreview {
                Text("+\(columns.count - Self.maxPreview) more columns")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
