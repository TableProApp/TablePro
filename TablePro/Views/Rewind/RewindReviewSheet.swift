//
//  RewindReviewSheet.swift
//  TablePro
//
//  What restoring a save would do, before it does it.
//
//  Every row says what will happen to it and why, including the ones that will be left alone,
//  because "3 of 5 rows will be restored" is only trustworthy if the other two are accounted for.
//

import SwiftUI
import TableProPluginKit

struct RewindReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let plan: RewindPlan
    let onRestore: () async -> Void

    @State private var isApplying = false
    @State private var isShowingStatements = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            rowList

            if isShowingStatements {
                Divider()
                statementList
            }

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 640, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Restore Previous Values")
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        String(
            format: String(
                localized: "%1$@, %2$@, saved %3$@. Triggers, audit rows and cascade deletes are not reversed."
            ),
            targetDescription,
            plan.record.summary,
            plan.record.capturedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    /// Names the database as well as the table: a restore reached from a history drawer scoped to
    /// every connection is not necessarily aimed where the window is pointing.
    private var targetDescription: String {
        let target = plan.record.target
        guard !target.database.isEmpty else { return target.qualifiedName }
        return "\(target.database).\(target.qualifiedName)"
    }

    private var rowList: some View {
        Table(plan.rows) {
            TableColumn(String(localized: "Row")) { row in
                Text(row.keyDescription)
                    .font(ThemeEngine.shared.valueFontSwiftUI)
                    .lineLimit(1)
            }
            TableColumn(String(localized: "Action")) { row in
                Text(row.actionDescription)
                    .lineLimit(1)
            }
            TableColumn(String(localized: "Outcome")) { row in
                Label {
                    Text(row.outcome.label)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: icon(for: row.outcome))
                        .foregroundStyle(tint(for: row.outcome))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var statementList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(displayStatements.enumerated()), id: \.offset) { _, statement in
                    Text(statement)
                        .font(Font(ThemeEngine.shared.editorFonts.font))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(height: 140)
    }

    private var displayStatements: [String] {
        plan.statements.map { SQLParameterInliner.inline($0, databaseType: plan.record.databaseType) }
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: $isShowingStatements) {
                Text("Show SQL")
            }
            .toggleStyle(.checkbox)
            .disabled(plan.statements.isEmpty)

            Spacer()

            Text(countSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(role: .cancel) {
                dismiss()
            } label: {
                Text("Cancel")
                    .frame(minWidth: 60)
            }
            .keyboardShortcut(.cancelAction)

            Button {
                isApplying = true
                Task {
                    await onRestore()
                    isApplying = false
                    dismiss()
                }
            } label: {
                Text("Restore")
                    .frame(minWidth: 60)
            }
            .disabled(!plan.canApply || isApplying)
        }
    }

    private var countSummary: String {
        if plan.skippedCount == 0 {
            return String(format: String(localized: "%d rows will be restored"), plan.restorableCount)
        }
        return String(
            format: String(localized: "%1$d will be restored, %2$d left alone"),
            plan.restorableCount,
            plan.skippedCount
        )
    }

    private func icon(for outcome: RewindRowOutcome) -> String {
        switch outcome {
        case .willRestore:
            return "arrow.uturn.backward.circle.fill"
        case .alreadyRestored:
            return "checkmark.circle"
        case .changedSinceSave, .rowAlreadyPresent:
            return "exclamationmark.triangle.fill"
        case .rowMissing, .notReversible:
            return "minus.circle"
        }
    }

    private func tint(for outcome: RewindRowOutcome) -> Color {
        switch outcome {
        case .willRestore:
            return .accentColor
        case .alreadyRestored:
            return .secondary
        case .changedSinceSave, .rowAlreadyPresent:
            return .orange
        case .rowMissing, .notReversible:
            return .secondary
        }
    }
}
