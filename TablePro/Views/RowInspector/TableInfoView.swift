//
//  TableInfoView.swift
//  TablePro
//

import SwiftUI

/// The table's own statistics, shown when the inspector has a table but no row selected.
///
/// Not a `Form`. `.formStyle(.grouped)` insets its content 30pt per side and there is no way to ask
/// it for less: measured, that 30 holds at 250, 270, 300, 340, 420 and 600pt, so it is not a margin
/// that gives way on a narrow pane. At the inspector's 270pt minimum it left a 116pt value column,
/// which truncated the collation on every engine whose collation has a name (`utf8mb4_0900_ai_ci`
/// needs 126pt, `SQL_Latin1_General_CP1_CI_AS` needs 196), and the previous author reached for a
/// `.help` tooltip on that row rather than the width. It also disagreed with the field list beside
/// it: selecting a row moved every value 20pt sideways.
///
/// So the sections are drawn here, on `InspectorMetrics.horizontalInset` like everything else in
/// the pane, and a value that still does not fit wraps rather than eliding. Wrapping is what
/// Finder's Get Info does with a long value at this width, measured.
internal struct TableInfoView: View {
    internal let metadata: TableMetadata

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if AppSettingsManager.shared.general.showObjectComments,
                   let comment = metadata.comment, !comment.isEmpty {
                    section(String(localized: "Comment")) {
                        Text(comment)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                section(String(localized: "Size")) {
                    row(String(localized: "Data"), TableMetadata.formatSize(metadata.dataSize))
                    row(String(localized: "Indexes"), TableMetadata.formatSize(metadata.indexSize))
                    row(String(localized: "Total"), TableMetadata.formatSize(metadata.totalSize))
                }

                if metadata.rowCount != nil || metadata.avgRowLength != nil {
                    section(String(localized: "Statistics")) {
                        if let rows = metadata.rowCount {
                            row(String(localized: "Rows"), rows.formatted(.number))
                        }
                        if let averageLength = metadata.avgRowLength {
                            row(String(localized: "Average Row"), TableMetadata.formatSize(averageLength))
                        }
                    }
                }

                if metadata.engine != nil || metadata.collation != nil {
                    section(String(localized: "Metadata")) {
                        if let engine = metadata.engine {
                            row(String(localized: "Engine"), engine)
                        }
                        if let collation = metadata.collation {
                            row(String(localized: "Collation"), collation)
                        }
                    }
                }

                if metadata.createTime != nil || metadata.updateTime != nil {
                    section(String(localized: "Timestamps")) {
                        if let created = metadata.createTime {
                            row(String(localized: "Created"), Self.date(created))
                        }
                        if let updated = metadata.updateTime {
                            row(String(localized: "Updated"), Self.date(updated))
                        }
                    }
                }
            }
            .padding(.horizontal, InspectorMetrics.horizontalInset)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.labelToValue) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// The label takes what it needs and the value takes the rest, wrapping when it has to. A fixed
    /// label lane would be wrong here for the same reason it is wrong on a data field: these labels
    /// are localized, so their widest member is not knowable from the English.
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private static func date(_ value: Date) -> String {
        value.formatted(date: .numeric, time: .shortened)
    }
}
