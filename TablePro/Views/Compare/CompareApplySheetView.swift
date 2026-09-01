//
//  CompareApplySheetView.swift
//  TablePro
//
//  The last thing shown before anything is written, and the record of what was.
//
//  Cancel is the default button and Apply is destructive, because this is the
//  only sheet in the app whose confirmation writes to someone else's database.
//  Every sentence names the target, so a user reading only one of them still
//  knows which database is about to change.
//

import SwiftUI

internal struct CompareApplySheetView: View {
    internal enum Choice {
        case cancel
        case apply
    }

    private struct PlannedObject: Identifiable {
        let name: String
        let count: Int

        var id: String { name }
    }

    private enum Pane: String, CaseIterable, Hashable {
        case script
        case summary
        case warnings

        var title: String {
            switch self {
            case .script:
                return String(localized: "Script")
            case .summary:
                return String(localized: "Summary")
            case .warnings:
                return String(localized: "Warnings")
            }
        }
    }

    @Bindable internal var session: CompareSyncSession
    internal let callback: (Choice) -> Void

    @AppStorage("structureCodeFontSize", store: AppStorageEnvironment.shared.defaults) private var fontSize = 13.0

    @State private var pane: Pane = .summary

    internal var body: some View {
        VStack(spacing: 0) {
            headline
            Divider()
            TabView(selection: $pane) {
                scriptPane
                    .tabItem { Text(Pane.script.title) }
                    .tag(Pane.script)
                summaryPane
                    .tabItem { Text(Pane.summary.title) }
                    .tag(Pane.summary)
                warningsPane
                    .tabItem { Text(Pane.warnings.title) }
                    .tag(Pane.warnings)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            Divider()
            actionRow
        }
        /// Apply is disabled while anything is held back and the action row says to go to Warnings,
        /// so the sheet opens on the tab that can actually unblock it.
        .onAppear {
            guard session.unacknowledgedHazardCount > 0 else { return }
            pane = .warnings
        }
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headlineText)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing is written until Apply.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// The count carries the noun and the target name follows it, so the singular cannot come from a
    /// plural variation on the format string and is chosen here instead.
    private var headlineText: String {
        let count = session.runnableStatementCount
        guard count != 1 else {
            return String(format: String(localized: "Apply 1 statement to %@?"), targetName)
        }
        return String(format: String(localized: "Apply %1$d statements to %2$@?"), count, targetName)
    }

    private var targetName: String {
        session.target?.qualifiedDescription ?? String(localized: "the target")
    }

    // MARK: - Script

    private var scriptPane: some View {
        DDLTextView(ddl: runnableScript, fontSize: $fontSize, databaseType: session.target?.databaseType)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runnableStatements: [SyncStatement] {
        session.statements.filter { session.executionSettings.canRun($0) }
    }

    private var runnableScript: String {
        runnableStatements.map { $0.sql }.joined(separator: "\n")
    }

    // MARK: - Summary

    private var summaryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let result = session.runResult {
                    runResultSection(result)
                    Divider()
                }
                plannedWorkSection
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var plannedWorkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: String(localized: "What will run against %@"), targetName))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(plannedObjects) { entry in
                HStack(spacing: 8) {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(entry.count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if session.unacknowledgedHazardCount > 0 {
                Label {
                    Text(heldBackText)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .foregroundStyle(CompareStatusStyle.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var plannedObjects: [PlannedObject] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for statement in runnableStatements {
            if counts[statement.objectName] == nil {
                order.append(statement.objectName)
            }
            counts[statement.objectName, default: 0] += 1
        }
        return order.map { PlannedObject(name: $0, count: counts[$0] ?? 0) }
    }

    /// What a held-back statement means, said the way the button behaves. This used to read as
    /// though the run went ahead without it, while Apply was in fact refusing to run at all until
    /// every one of them was allowed.
    private var heldBackText: String {
        let count = session.unacknowledgedHazardCount
        guard count != 1 else {
            return String(localized: "1 statement would destroy data. Allow it or exclude it before applying.")
        }
        return String(
            format: String(localized: "%d statements would destroy data. Allow them or exclude them before applying."),
            count
        )
    }

    // MARK: - Run result

    private func runResultSection(_ result: CompareSyncRunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: String(localized: "What ran against %@"), targetName))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                countBadge(
                    String(localized: "Ran"), result.executedCount,
                    symbol: "checkmark.circle.fill", tint: CompareStatusStyle.success
                )
                countBadge(
                    String(localized: "Failed"), result.failedCount,
                    symbol: "xmark.circle.fill", tint: CompareStatusStyle.error
                )
                countBadge(
                    String(localized: "Held back"), result.heldBackCount,
                    symbol: "hand.raised.fill", tint: CompareStatusStyle.warning
                )
                Spacer(minLength: 0)
            }

            if result.rolledBack {
                noticeLabel(
                    String(format: String(localized: "The run was rolled back. %@ is unchanged."), targetName),
                    systemImage: "arrow.uturn.backward.circle.fill"
                )
            } else if result.failedCount > 0 {
                noticeLabel(
                    String(
                        format: String(localized: "Statements that already ran stay applied to %@. Compare again to see where it stands."),
                        targetName
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
            }

            if let commitFailure = result.commitFailure {
                Label {
                    Text(String(
                        format: String(
                            localized: "The statements ran but the transaction could not be committed: %@"
                        ),
                        commitFailure
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                }
                .foregroundStyle(CompareStatusStyle.error)
            }

            if result.cancelled {
                noticeLabel(
                    String(localized: "Cancelled before the script finished."),
                    systemImage: "stop.circle"
                )
            }

            ForEach(result.outcomes) { outcome in
                outcomeRow(outcome)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outcomeRow(_ outcome: SyncStatementOutcome) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbolName(for: outcome))
                    .foregroundStyle(tint(for: outcome))
                Text(outcome.statement.summary)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(stateLabel(for: outcome))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = outcome.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(CompareStatusStyle.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func symbolName(for outcome: SyncStatementOutcome) -> String {
        if outcome.wasSkipped { return "hand.raised.fill" }
        return outcome.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func tint(for outcome: SyncStatementOutcome) -> Color {
        if outcome.wasSkipped { return CompareStatusStyle.warning }
        return outcome.error == nil ? CompareStatusStyle.success : CompareStatusStyle.error
    }

    private func stateLabel(for outcome: SyncStatementOutcome) -> String {
        if outcome.wasSkipped { return String(localized: "Held back") }
        return outcome.error == nil ? String(localized: "Ran") : String(localized: "Failed")
    }

    // MARK: - Warnings

    /// The tab the action row sends people to, so the allowance has to be reachable here. It used to
    /// render the hazards read-only while Apply stayed disabled until every one of them was allowed,
    /// and the only checkbox that could allow one lived in the script pane behind this sheet.
    private var warningsPane: some View {
        Group {
            if hazardStatements.isEmpty {
                ContentUnavailableView {
                    Label("No Warnings", systemImage: "checkmark.shield")
                } description: {
                    Text(String(format: String(localized: "Nothing in this script destroys data in %@."), targetName))
                }
            } else {
                List {
                    Section {
                        ForEach(hazardStatements) { statement in
                            hazardRow(statement)
                        }
                    } footer: {
                        Text("Allowing a statement applies to this run only. It is never saved.")
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var hazardStatements: [SyncStatement] {
        session.statements.filter { !$0.hazards.isEmpty }
    }

    private func hazardRow(_ statement: SyncStatement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                hazardHeadline(statement)
                Spacer(minLength: 0)
                Text(session.executionSettings.canRun(statement)
                    ? String(localized: "Will run")
                    : String(localized: "Held back"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(statement.hazards) { hazard in
                VStack(alignment: .leading, spacing: 1) {
                    Text(hazard.kind.displayName)
                        .font(.caption.weight(.semibold))
                    Text(hazard.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(statement.sql)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    /// Only a statement the classifier refuses by default has an allowance to grant. A hazard that
    /// runs anyway gets a label rather than a checkbox, because a checkbox that cannot stop it would
    /// say the opposite of what it does.
    @ViewBuilder
    private func hazardHeadline(_ statement: SyncStatement) -> some View {
        if statement.isRefusedByDefault {
            Toggle(isOn: CompareHazardAllowance.binding(for: statement, in: session)) {
                Text(statement.summary)
                    .font(.callout)
                    .lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("compare.apply.allow.\(statement.id.uuidString)")
        } else {
            Label {
                Text(statement.summary)
                    .font(.callout)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "play.circle.fill")
            }
            .foregroundStyle(CompareStatusStyle.warning)
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 12) {
            if session.unacknowledgedHazardCount > 0 {
                Label {
                    Text("Allow every held-back statement on the Warnings tab, or exclude the objects that produced them, before applying.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .font(.callout)
                .foregroundStyle(CompareStatusStyle.warning)
            }
            Spacer(minLength: 0)
            Button("Cancel") {
                callback(.cancel)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("compare.apply.cancel")
            Button(applyTitle, role: .destructive) {
                callback(.apply)
            }
            .disabled(!canApply)
            .accessibilityIdentifier("compare.apply.confirm")
        }
        .padding(16)
    }

    private var applyTitle: String {
        String(format: String(localized: "Apply to %@"), targetName)
    }

    private var canApply: Bool {
        session.runRefusalReason == nil
    }

    private func countBadge(_ label: String, _ count: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(count > 0 ? tint : Color.secondary)
            Text(label)
            Text(count, format: .number)
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.callout)
    }

    private func noticeLabel(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(CompareStatusStyle.warning)
    }
}
