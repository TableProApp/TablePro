//
//  CopyObjectsReviewView.swift
//  TablePro
//
//  The second step: what will run, before it runs.
//
//  The DDL is shown verbatim. The rows are shown as the query each table will
//  walk and the count it expects, because the INSERTs do not exist yet and
//  never all exist at once.
//

import SwiftUI

internal struct CopyObjectsReviewView: View {
    internal let session: ObjectCopySession

    internal var body: some View {
        if let plan = session.plan {
            HSplitView {
                summary(plan)
                    .frame(minWidth: 260, idealWidth: 300)
                script(plan)
                    .frame(minWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading both databases…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Summary

    private func summary(_ plan: ObjectCopyPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headline(plan)
                ForEach(plan.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                rowPlan(plan)
                conversions(plan)
                notes(plan)
                skipped(plan)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func headline(_ plan: ObjectCopyPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(
                format: String(localized: "Writing to %@"),
                plan.request.target.qualifiedDescription
            ))
            .font(.headline)
            if plan.createsDatabase {
                Text(String(
                    format: String(localized: "A new database named %@ is created first."),
                    plan.request.target.database
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func rowPlan(_ plan: ObjectCopyPlan) -> some View {
        let steps = plan.dataSteps
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rows")
                    .font(.subheadline.weight(.medium))
                ForEach(steps) { step in
                    HStack(spacing: 8) {
                        Text(step.qualifiedTargetName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(rowEstimate(step))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// A driver that reports no estimate says so rather than showing a zero, which would read as an
    /// empty table.
    private func rowEstimate(_ step: ObjectCopyTableStep) -> String {
        guard let rows = step.estimatedRows else { return String(localized: "Unknown") }
        let template = rows == 1
            ? String(localized: "about %@ row")
            : String(localized: "about %@ rows")
        return String(format: template, rows.formatted(.number.grouping(.automatic)))
    }

    /// What the crossing between two engines changed, one row per column or index.
    ///
    /// Listed rather than summarised, because "some types were converted" is not something a user
    /// can act on and "amount: DECIMAL(19,4) → NUMBER(19,4)" is. A row that loses something carries
    /// the same warning triangle the copy's own caveats use; a widening reads as ordinary text,
    /// because every value still fits and there is nothing to decide.
    @ViewBuilder
    private func conversions(_ plan: ObjectCopyPlan) -> some View {
        let notes = plan.reviewedConversionNotes()
        if !notes.shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Type changes")
                    .font(.subheadline.weight(.medium))
                ForEach(notes.shown) { note in
                    conversion(note)
                }
                if notes.hidden > 0 {
                    Text(String(
                        format: String(localized: "%@ more, in the script beside this"),
                        notes.hidden.formatted(.number.grouping(.automatic))
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func conversion(_ note: CrossEngineConversionNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(note.summary)
            } icon: {
                Image(systemName: note.isLossy ? "exclamationmark.triangle" : "arrow.right.circle")
            }
            .font(.callout)
            .foregroundStyle(note.isLossy ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(note.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func notes(_ plan: ObjectCopyPlan) -> some View {
        let noted = plan.tableSteps.compactMap { step in step.note.map { (step.id, step.selection, $0) } }
        if !noted.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Partly copied")
                    .font(.subheadline.weight(.medium))
                ForEach(noted, id: \.0) { _, selection, note in
                    Text(verbatim: "\(selection.displayName): \(note)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func skipped(_ plan: ObjectCopyPlan) -> some View {
        if !plan.skipped.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Left out")
                    .font(.subheadline.weight(.medium))
                ForEach(plan.skipped) { skip in
                    Text(verbatim: "\(skip.selection.displayName): \(skip.reason)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Script

    /// The same read-only editor the import preview uses, so the script arrives with the user's
    /// editor font, their theme and SQL highlighting rather than as plain text.
    private func script(_ plan: ObjectCopyPlan) -> some View {
        SQLCodePreview(text: .constant(plan.scriptText))
            .accessibilityIdentifier("copy-objects-script")
    }
}
