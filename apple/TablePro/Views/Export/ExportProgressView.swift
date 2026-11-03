//
//  ExportProgressView.swift
//  TablePro
//

import SwiftUI

// The dialog holds its service in an optional, which no property wrapper can observe.
struct ExportProgressSheet: View {
    @ObservedObject var service: ExportService
    let fileName: String
    let onStop: () -> Void

    var body: some View {
        TransferProgressSheet(progress: service.state.transferProgress(fileName: fileName), onStop: onStop)
    }
}

extension ExportState {
    // A streaming query has no current table, so it is named by the file it is written to.
    func transferProgress(fileName: String) -> TransferProgress {
        let subject = currentTable.isEmpty
            ? (fileName.isEmpty ? String(localized: "Query results") : fileName)
            : currentTable
        let status = statusMessage.isEmpty ? estimateNote : statusMessage
        guard readsRows else {
            return TransferProgress(
                job: .export,
                item: subject,
                completed: Int64(min(currentTableIndex, totalTables)),
                total: Int64(totalTables),
                unit: .objects,
                note: status
            )
        }
        return TransferProgress(
            job: .export,
            item: subject,
            step: TransferProgress.Step(index: max(currentTableIndex, 1), count: totalTables),
            completed: Int64(processedRows),
            total: Int64(totalRows),
            unit: .rows,
            isEstimate: rowTotalIsEstimate,
            note: status
        )
    }
}
