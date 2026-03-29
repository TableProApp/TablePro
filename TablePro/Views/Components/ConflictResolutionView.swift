//
//  ConflictResolutionView.swift
//  TablePro
//
//  Sheet for resolving sync conflicts between local and remote versions
//

import CloudKit
import SwiftUI

struct ConflictResolutionView: View {
    @Bindable private var conflictResolver = ConflictResolver.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let conflict = conflictResolver.currentConflict {
            VStack(spacing: 16) {
                header(for: conflict)
                description(for: conflict)
                comparisonBoxes(for: conflict)
                actionButtons(for: conflict)
                progressIndicator
            }
            .padding(24)
            .frame(width: 500)
        }
    }

    // MARK: - Header

    private func header(for conflict: SyncConflict) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(String(localized: "Sync Conflict"))
                .font(.headline)
        }
    }

    // MARK: - Description

    private func description(for conflict: SyncConflict) -> some View {
        Group {
            if conflict.recordType == .settings {
                Text(String(localized: "Settings were changed on both this Mac and another device."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    String(
                        localized: "\"\(conflict.entityName)\" was modified on both this Mac and another device."
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Comparison Boxes

    private func comparisonBoxes(for conflict: SyncConflict) -> some View {
        HStack(spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(String(localized: "This Mac"), systemImage: "desktopcomputer")
                        .font(.subheadline.bold())

                    Divider()

                    LabeledContent(String(localized: "Modified:")) {
                        Text(conflict.localModifiedAt, style: .date)
                        Text(conflict.localModifiedAt, style: .time)
                    }
                    .font(.caption)

                    changedFields(from: conflict.localRecord, conflict: conflict)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(String(localized: "Other Device"), systemImage: "laptopcomputer")
                        .font(.subheadline.bold())

                    Divider()

                    LabeledContent(String(localized: "Modified:")) {
                        Text(conflict.serverModifiedAt, style: .date)
                        Text(conflict.serverModifiedAt, style: .time)
                    }
                    .font(.caption)

                    changedFields(from: conflict.serverRecord, conflict: conflict)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    @ViewBuilder
    private func changedFields(from record: CKRecord, conflict: SyncConflict) -> some View {
        switch conflict.recordType {
        case .connection:
            if let host = record["host"] as? String {
                fieldRow(label: "Host", value: host)
            }
            if let port = record["port"] as? Int64 {
                fieldRow(label: "Port", value: "\(port)")
            }
            if let database = record["database"] as? String {
                fieldRow(label: "Database", value: database)
            }
            if let username = record["username"] as? String {
                fieldRow(label: "User", value: username)
            }
        case .settings:
            Text(String(localized: "Settings were changed"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .group, .tag:
            if let name = record["name"] as? String {
                fieldRow(label: "Name", value: name)
            }
            if let color = record["color"] as? String {
                fieldRow(label: "Color", value: color)
            }
        case .favorite, .favoriteFolder:
            if let name = record["name"] as? String {
                fieldRow(label: String(localized: "Name"), value: name)
            }
        case .sshProfile:
            if let name = record["name"] as? String {
                fieldRow(label: String(localized: "Name"), value: name)
            }
            if let host = record["host"] as? String {
                fieldRow(label: "Host", value: host)
            }
        }
    }

    private func fieldRow(label: String, value: String) -> some View {
        LabeledContent(label + ":") {
            Text(value)
                .lineLimit(1)
        }
        .font(.caption)
    }

    // MARK: - Action Buttons

    private func actionButtons(for conflict: SyncConflict) -> some View {
        HStack(spacing: 12) {
            Button(String(localized: "Keep Other Version")) {
                resolveConflict(keepLocal: false)
            }
            .buttonStyle(.bordered)

            Button(String(localized: "Keep This Mac's Version")) {
                resolveConflict(keepLocal: true)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Progress

    private var progressIndicator: some View {
        Group {
            let total = conflictResolver.pendingConflicts.count
            if total > 1 {
                Text(
                    String(
                        localized: "1 of \(total) conflicts"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func resolveConflict(keepLocal: Bool) {
        let resolvedRecord = conflictResolver.resolveCurrentConflict(keepLocal: keepLocal)

        if let record = resolvedRecord {
            SyncCoordinator.shared.pushResolvedConflict(record)
        }

        if !conflictResolver.hasConflicts {
            dismiss()
        }
    }
}

#Preview {
    ConflictResolutionView()
        .frame(width: 500)
}
