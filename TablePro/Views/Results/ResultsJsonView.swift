//
//  ResultsJsonView.swift
//  TablePro
//

import SwiftUI

internal struct ResultsJsonView: View {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[String?]]
    let selectedRowIndices: Set<Int>

    private var displayRows: [[String?]] {
        if selectedRowIndices.isEmpty {
            return rows
        }
        return selectedRowIndices.sorted().compactMap { idx in
            rows.indices.contains(idx) ? rows[idx] : nil
        }
    }

    private var jsonString: String {
        let converter = JsonRowConverter(columns: columns, columnTypes: columnTypes)
        return converter.generateJson(rows: displayRows)
    }

    private var rowCountText: String {
        let displaying = displayRows.count
        let total = rows.count
        if selectedRowIndices.isEmpty || displaying == total {
            return String(format: String(localized: "%d rows"), total)
        }
        return String(format: String(localized: "%d of %d rows"), displaying, total)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(rowCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    ClipboardService.shared.writeText(jsonString)
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if rows.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Data"),
                    systemImage: "curlybraces",
                    description: Text(String(localized: "Execute a query to view results as JSON"))
                )
            } else {
                JSONViewerView(
                    text: .constant(jsonString),
                    isEditable: false
                )
            }
        }
    }
}
