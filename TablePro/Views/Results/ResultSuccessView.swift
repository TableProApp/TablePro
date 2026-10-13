//
//  ResultSuccessView.swift
//  TablePro
//
//  Compact DDL/DML success view for the results panel.
//  Replaces the full-screen QuerySuccessView for multi-result contexts.
//

import SwiftUI
import TableProPluginKit

struct ResultSuccessView: View {
    let rowsAffected: Int
    let executionTime: TimeInterval?
    let statusMessage: String?
    var serverOutput: PluginServerOutput = .none

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
        if serverOutput.isEmpty {
            summary
        } else {
            VStack(spacing: 0) {
                compactSummary
                Divider()
                ServerOutputView(output: serverOutput)
            }
        }
    }

    /// The summary on one line, so the output under it gets the height.
    private var compactSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(primaryMessage)
            if let time = executionTime {
                Text(String(format: "%.3fs", time))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
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

#Preview("With output") {
    ResultSuccessView(
        rowsAffected: 0,
        executionTime: 0.012,
        statusMessage: nil,
        serverOutput: PluginServerOutput(lines: ["Hello from PL/SQL"], isTruncated: false)
    )
    .frame(width: 400, height: 300)
}
