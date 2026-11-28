//
//  SyncApprovalReviewSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// The changes another device made that wait for the person on this Mac (core ADR 0044, Fields a pull applies only with
// approval). A List, so a new Mac pulling a whole library builds only the rows on screen. Return approves nothing.
internal struct SyncApprovalReviewSheet: View {
    @ObservedObject var model: SyncApprovalsModel
    var lookup: SyncApprovalLookup = .live

    @Environment(\.dismiss) private var dismiss
    // The sheet closes on its own once the last record is decided, never while the first read is still out.
    @State private var hadRecords = false

    var body: some View {
        let items = SyncApprovalPresentation.items(model.records, lookup: lookup)
        let personal = items.filter { !$0.isTeam }
        let team = items.filter(\.isTeam)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Changes Waiting for Your Approval")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    """
                    Your other devices changed these. They can change where a connection signs in, what it runs when it \
                    connects, or what AI features send, so nothing here applies on this Mac until you approve it.
                    """
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            List {
                if !personal.isEmpty {
                    Section(String(localized: "Your Library")) {
                        rows(personal)
                    }
                }
                if !team.isEmpty {
                    Section(String(localized: "Team Library")) {
                        rows(team)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if items.isEmpty {
                    emptyState
                }
            }

            Divider()

            DialogFooter {
                footerStatus
            } actions: {
                // Not the default button: Return never approves everything. The records are the ones on screen.
                let shown = items.map(\.record)
                Button(String(localized: "Approve All")) {
                    Task { await model.approveAll(shown) }
                }
                .disabled(items.isEmpty || model.isDeciding)
                .accessibilityHint(Text("Applies every change listed on this Mac"))
                .accessibilityIdentifier("sync-approvals-approve-all")

                Button(String(localized: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sync-approvals-done")
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-approvals-sheet")
        .task { await model.refresh() }
        .onValueChange(of: model.records.isEmpty) { _, isEmpty in
            if !isEmpty {
                hadRecords = true
            } else if hadRecords {
                dismiss()
            }
        }
        .onAppear {
            hadRecords = !model.records.isEmpty
        }
    }

    @ViewBuilder
    private func rows(_ items: [SyncApprovalItem]) -> some View {
        ForEach(items) { item in
            SyncApprovalRecordRow(
                item: item,
                isDeciding: model.deciding.contains(item.id),
                isDisabled: model.isDeciding,
                failure: model.failure?.record == item.id ? model.failure?.message : nil,
                // The copy on screen, never one read since, so the digest matches what the person saw.
                decide: { approve in
                    Task { await model.decide(item.record, approve: approve) }
                }
            )
        }
    }

    // Nothing waiting is said only after a read confirmed it.
    @ViewBuilder
    private var emptyState: some View {
        if model.readFailed {
            VStack(spacing: 8) {
                Text("The changes could not be read.")
                    .foregroundStyle(.secondary)
                Button(String(localized: "Try Again")) {
                    Task { await model.refresh() }
                }
                .accessibilityIdentifier("sync-approvals-retry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sync-approvals-read-failed")
        } else if !model.hasRead {
            ProgressView(String(localized: "Loading…"))
                .controlSize(.small)
                .accessibilityIdentifier("sync-approvals-loading")
        } else {
            Text("No changes are waiting.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("sync-approvals-empty")
        }
    }

    @ViewBuilder
    private var footerStatus: some View {
        if let failure = model.failure, failure.record == nil {
            Label(failure.message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sync-approvals-failure")
        } else if model.deciding.count > 1 {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(SyncApprovalPresentation.approvingLine(model.deciding.count))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sync-approvals-progress")
        } else if !model.records.isEmpty {
            Text(SyncApprovalPresentation.waitingLine(model.records.count))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("sync-approvals-count")
        }
    }
}

// One record: what it is, then each value that waits, from this Mac's value to the pulled one.
private struct SyncApprovalRecordRow: View {
    let item: SyncApprovalItem
    let isDeciding: Bool
    let isDisabled: Bool
    let failure: String?
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("sync-approval-title-\(item.id.recordId)")

                Spacer(minLength: 12)

                if isDeciding {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Saving your choice"))
                }

                Button(String(localized: "Don't Apply")) { decide(false) }
                    .accessibilityLabel(Text(String(format: String(localized: "Don't Apply %@"), item.title)))
                    .accessibilityHint(Text(rejectHint))
                    .accessibilityIdentifier("sync-approval-reject-\(item.id.recordId)")

                Button(String(localized: "Approve")) { decide(true) }
                    .accessibilityLabel(Text(String(format: String(localized: "Approve %@"), item.title)))
                    .accessibilityHint(Text("Applies these values on this Mac"))
                    .accessibilityIdentifier("sync-approval-approve-\(item.id.recordId)")
            }
            .disabled(isDisabled)

            // One element per value, label and change together, as VoiceOver reads it.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(item.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 160, alignment: .trailing)
                        SyncApprovalChange(row: row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(SyncApprovalPresentation.spoken(row)))
                    .accessibilityIdentifier("sync-approval-field-\(item.id.recordId)-\(row.id)")
                }
            }
            .padding(.leading, 34)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 34)
                    .accessibilityIdentifier("sync-approval-failure-\(item.id.recordId)")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(item.title), \(item.subtitle)"))
        .accessibilityIdentifier("sync-approval-\(item.id.kind)-\(item.id.recordId)")
    }

    private var rejectHint: String {
        item.isNew
            ? String(localized: "Keeps this item off this Mac")
            : String(localized: "Keeps this Mac's values")
    }
}

// This Mac's value, an arrow, then the pulled one; a new record shows only the pulled one. Code and lists stack the two.
private struct SyncApprovalChange: View {
    let row: SyncApprovalItem.Row

    var body: some View {
        if Self.isBlock(row.to) || row.from.map(Self.isBlock) == true {
            VStack(alignment: .leading, spacing: 4) {
                if let from = row.from {
                    SyncApprovalValueView(value: from, isOld: true)
                    Image(systemName: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                SyncApprovalValueView(value: row.to, isOld: false)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let from = row.from {
                    SyncApprovalValueView(value: from, isOld: true)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                SyncApprovalValueView(value: row.to, isOld: false)
            }
        }
    }

    private static func isBlock(_ value: SyncApprovalItem.Value) -> Bool {
        switch value {
        case .code, .lines: true
        case .text, .notSet, .hidden: false
        }
    }
}

private struct SyncApprovalValueView: View {
    let value: SyncApprovalItem.Value
    let isOld: Bool

    // Never cut short: a value the person approves is shown whole, however long.
    var body: some View {
        switch value {
        case .text(let text):
            Text(text)
                .foregroundStyle(isOld ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(isOld ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .lines(let lines):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .foregroundStyle(isOld ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        case .notSet, .hidden:
            Text(SyncApprovalPresentation.spoken(value))
                .foregroundStyle(.secondary)
                .italic(value == .hidden)
        }
    }
}
