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

// The export sheet's root while an offered format's plugin installs, in place of a panel on top of the sheet.
struct PluginInstallProgressSheet: View {
    @ObservedObject var install: PluginInstallRun

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(install.display.message)
                    .lineLimit(1)
                    .truncationMode(.middle)
                bar
                    .accessibilityLabel(install.display.message)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    install.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(!install.canCancel)
            }
        }
        .controlSize(.regular)
        .padding(20)
        .frame(width: TransferProgressView.sheetWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-install-progress")
    }

    @ViewBuilder
    private var bar: some View {
        if let fraction = install.display.fraction {
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
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
