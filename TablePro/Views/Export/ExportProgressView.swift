//
//  ExportProgressView.swift
//  TablePro
//
//  Progress dialog shown during table export.
//  Displays table name, row progress, progress bar, and stop button.
//

import SwiftUI

/// Progress dialog shown during export operation
struct ExportProgressView: View {
    let tableName: String
    let tableIndex: Int
    let totalTables: Int
    let processedRows: Int
    let totalRows: Int
    let statusMessage: String
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Title
            Text(totalTables > 1
                ? String(localized: "Export multiple tables")
                : String(localized: "Export table"))
                .font(.title3.weight(.semibold))

            // Table info and row count
            VStack(spacing: 8) {
                HStack {
                    // Show status message if set, otherwise show table name
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(tableName) (\(tableIndex)/\(totalTables))")
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if statusMessage.isEmpty {
                        Text("\(processedRows.formatted())/\(totalRows.formatted()) rows")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // Progress bar - indeterminate when status message is shown
                if !statusMessage.isEmpty {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                }
            }

            // Stop button
            Button("Stop") {
                onStop()
            }
            .frame(width: 80)
        }
        .padding(24)
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var progressValue: Double {
        guard totalRows > 0 else { return 0 }
        return Double(processedRows) / Double(totalRows)
    }
}

// MARK: - Preview

#Preview {
    ExportProgressView(
        tableName: "users",
        tableIndex: 1,
        totalTables: 3,
        processedRows: 95_500,
        totalRows: 175_787,
        statusMessage: ""
    )        {}
}
