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

    private var primaryMessage: String {
        if rowsAffected == 0, let status = statusMessage, !status.isEmpty {
            return status
        }
        if rowsAffected == 0 {
            return String(localized: "Query executed successfully")
        }
        return String(format: String(localized: "%lld row(s) affected"), Int64(rowsAffected))
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text(primaryMessage)
                .font(.body)
            if let time = executionTime {
                Text(String(format: "%.3fs", time))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if rowsAffected > 0, let status = statusMessage, !status.isEmpty {
                Text(status)
                    .font(.subheadline)
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
