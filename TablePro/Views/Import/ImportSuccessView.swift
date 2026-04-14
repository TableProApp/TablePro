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

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color(nsColor: .systemGreen))

            VStack(spacing: 6) {
                Text("Import Successful")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.title3, weight: .semibold))

                if let result {
                    Text("\(result.executedStatements) statements executed")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                        .foregroundStyle(.secondary)

                    let formattedTime = String(format: "%.2f", result.executionTime)
                    Text(String(format: String(localized: "%@ seconds"), formattedTime))
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Button("Close") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
