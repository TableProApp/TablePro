//
//  ResultSuccessView.swift
//  TablePro
//
//  Compact DDL/DML success view for the results panel.
//  Replaces the full-screen QuerySuccessView for multi-result contexts.
//

import SwiftUI

struct ResultSuccessView: View {
    let rowsAffected: Int
    let executionTime: TimeInterval?
    let statusMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text(String(format: String(localized: "%lld row(s) affected"), Int64(rowsAffected)))
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
            if let time = executionTime {
                Text(String(format: "%.3fs", time))
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
            }
            if let status = statusMessage, !status.isEmpty {
                Text(status)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ResultSuccessView(
        rowsAffected: 5,
        executionTime: 0.042,
        statusMessage: "Processed: 1.5 GB"
    )
    .frame(width: 400, height: 300)
}
