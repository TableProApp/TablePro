//
//  ExportProgressView.swift
//  TablePro
//

import SwiftUI

/// What the export is working on and how far through it is.
///
/// A determinate bar is drawn only when there is a total to be a fraction of. A streaming query has
/// no row count until it ends, so the bar used to sit at zero for the whole run beside a label
/// reading "18,204/0 rows", which says the export is stuck rather than that its size is unknown.
struct ExportProgressView: View {
    /// What is being exported, named by the caller. Deriving it from the table index reads
    /// " (0/1)" on the streaming path, where no table is ever current.
    let subject: String
    let tableIndex: Int
    let totalTables: Int
    let processedRows: Int
    let totalRows: Int
    let statusMessage: String
    let onStop: () -> Void

    @State private var showStopConfirmation = false

    private var hasRowTotal: Bool { totalRows > 0 }

    private var title: String {
        totalTables > 1
            ? String(localized: "Export multiple tables")
            : String(localized: "Export table")
    }

    private var subjectLabel: String {
        guard totalTables > 1 else { return subject }
        return String(
            format: String(localized: "%1$@ (%2$lld of %3$lld)"),
            subject, Int64(tableIndex), Int64(totalTables))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.title3.weight(.semibold))

            VStack(spacing: 8) {
                HStack {
                    if statusMessage.isEmpty {
                        Text(subjectLabel)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(statusMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if statusMessage.isEmpty {
                        Text(rowCountLabel)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if statusMessage.isEmpty, hasRowTotal {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

            Button("Stop") {
                showStopConfirmation = true
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(String(localized: "Stop Export?"), isPresented: $showStopConfirmation) {
            Button(String(localized: "Continue"), role: .cancel) {}
            Button(String(localized: "Stop"), role: .destructive) { onStop() }
        } message: {
            Text("Partial files may remain on disk.")
        }
    }

    private var rowCountLabel: String {
        guard hasRowTotal else {
            return String(format: String(localized: "%@ rows"), processedRows.formatted())
        }
        return String(
            format: String(localized: "%1$@/%2$@ rows"),
            processedRows.formatted(), totalRows.formatted())
    }

    private var progressValue: Double {
        guard totalRows > 0 else { return 0 }
        return min(1.0, Double(processedRows) / Double(totalRows))
    }
}

// MARK: - Preview

#Preview {
    ExportProgressView(
        subject: "users",
        tableIndex: 1,
        totalTables: 3,
        processedRows: 95_500,
        totalRows: 175_787,
        statusMessage: ""
    )        {}
}
