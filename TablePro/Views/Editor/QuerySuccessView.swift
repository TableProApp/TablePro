//
//  QuerySuccessView.swift
//  TablePro
//
//  Success message view for non-SELECT queries (INSERT, UPDATE, DELETE, etc.)
//

import SwiftUI

/// Displays success message for queries that don't return result sets
struct QuerySuccessView: View {
    let rowsAffected: Int
    let executionTime: TimeInterval?
    let statusMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            // Success message
            Text("Query executed successfully")
                .font(.headline)
                .foregroundStyle(.primary)

            // Details
            HStack(spacing: 8) {
                // Rows affected
                Label("\(rowsAffected) row\(rowsAffected == 1 ? "" : "s") affected", systemImage: "square.stack.3d.up")
                    .foregroundStyle(.secondary)

                if let time = executionTime {
                    Text("•")
                        .foregroundStyle(.tertiary)

                    // Execution time
                    Text(formatExecutionTime(time))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func formatExecutionTime(_ time: TimeInterval) -> String {
        if time < 0.001 {
            let ms = String(format: "%.3f", time * 1_000)
            return String(localized: "\(ms) ms")
        } else if time < 1 {
            let ms = String(format: "%.2f", time * 1_000)
            return String(localized: "\(ms) ms")
        } else {
            let secs = String(format: "%.2f", time)
            return String(localized: "\(secs) s")
        }
    }
}

#Preview {
    QuerySuccessView(rowsAffected: 3, executionTime: 0.025, statusMessage: "Processed: 1.5 GB | Billed: 1.5 GB | ~$0.01")
        .frame(width: 400, height: 300)
}
