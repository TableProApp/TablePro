//
//  ImportSuccessView.swift
//  TablePro
//
//  Success dialog shown after successful import.
//

import SwiftUI
import TableProPluginKit

struct ImportSuccessView: View {
    let result: PluginImportResult?
    let onClose: () -> Void

    private var hasErrors: Bool {
        guard let result else { return false }
        return result.skippedStatements > 0
    }

    var body: some View {
        VStack(spacing: 20) {
            if hasErrors {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(nsColor: .systemYellow))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            }

            VStack(spacing: 6) {
                Text(hasErrors ? "Import Completed with Errors" : "Import Successful")
                    .font(.title3.weight(.semibold))

                if let result {
                    if hasErrors {
                        Text("\(result.executedStatements) statements executed, \(result.skippedStatements) failed")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(result.executedStatements) statements executed")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    let formattedTime = String(format: "%.2f", result.executionTime)
                    Text(String(format: String(localized: "%@ seconds"), formattedTime))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let result, !result.errors.isEmpty {
                errorListView(errors: result.errors)
            }

            HStack(spacing: 12) {
                if let result, !result.errors.isEmpty {
                    Button("Copy Errors to Clipboard") {
                        copyErrorsToClipboard(errors: result.errors)
                    }
                }

                Button("Close") {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: hasErrors ? 500 : 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func errorListView(errors: [PluginImportResult.ImportStatementError]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Line \(error.line): \(error.statement)")
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(2)

                        Text(error.errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 200)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func copyErrorsToClipboard(errors: [PluginImportResult.ImportStatementError]) {
        let text = errors.map { error in
            "Line \(error.line): \(error.statement)\nError: \(error.errorMessage)"
        }.joined(separator: "\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
