//
//  CompareSyncApplyView.swift
//  TablePro
//
//  Per-statement outcome of a run, including what was held back and whether the
//  run rolled back.
//

import SwiftUI

internal struct CompareSyncApplyView: View {
    internal let session: CompareSyncSession

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            Divider()
            outcomeList
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let result = session.runResult {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    countBadge(
                        String(localized: "Executed"), result.executedCount,
                        "checkmark.circle.fill", result.executedCount > 0 ? .green : .secondary
                    )
                    countBadge(
                        String(localized: "Failed"), result.failedCount,
                        "xmark.circle.fill", result.failedCount > 0 ? .red : .secondary
                    )
                    countBadge(
                        String(localized: "Held back"), result.heldBackCount,
                        "hand.raised.fill", result.heldBackCount > 0 ? .orange : .secondary
                    )
                    Spacer()
                }

                if result.rolledBack {
                    Label(
                        String(localized: "The run was rolled back. The target is unchanged."),
                        systemImage: "arrow.uturn.backward.circle.fill"
                    )
                    .foregroundStyle(.orange)
                } else if result.failedCount > 0 {
                    Label(
                        String(localized: "Statements that already ran stay applied. Compare again to see the current state."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                if result.cancelled {
                    Label(String(localized: "Cancelled before the script finished."), systemImage: "stop.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        } else {
            Text("Nothing has run yet.")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }

    private func countBadge(_ label: String, _ count: Int, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text("\(label): \(count)")
        }
        .font(.callout)
    }

    private var outcomeList: some View {
        List(session.runResult?.outcomes ?? []) { outcome in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: outcome))
                        .foregroundStyle(tint(for: outcome))
                    Text(outcome.statement.summary)
                        .font(.callout)
                    Spacer()
                    Text(stateLabel(for: outcome))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(outcome.statement.sql)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                if let error = outcome.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private func symbol(for outcome: SyncStatementOutcome) -> String {
        if outcome.wasSkipped { return "hand.raised.fill" }
        return outcome.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func tint(for outcome: SyncStatementOutcome) -> Color {
        if outcome.wasSkipped { return .orange }
        return outcome.error == nil ? .green : .red
    }

    private func stateLabel(for outcome: SyncStatementOutcome) -> String {
        if outcome.wasSkipped { return String(localized: "Held back") }
        return outcome.error == nil ? String(localized: "Ran") : String(localized: "Failed")
    }
}
