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
                .font(.largeTitle)
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text(String(format: String(localized: "%lld row(s) affected"), Int64(rowsAffected)))
                .font(.body)
            if let time = executionTime {
                Text(String(format: "%.3fs", time))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let status = statusMessage, !status.isEmpty {
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
