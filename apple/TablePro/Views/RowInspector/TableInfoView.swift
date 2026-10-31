//
//  TableInfoView.swift
//  TablePro
//

import SwiftUI

// The table's own statistics, when the inspector has a table but no row selected. Not a grouped `Form`: its 30pt
// insets hold at every pane width and left a 116pt value column at 270pt, which truncated collation names.
internal struct TableInfoView: View {
    internal let metadata: TableMetadata

    var body: some View {
        ScrollView {
            TableInfoSections(metadata: metadata)
                .padding(.horizontal, InspectorMetrics.horizontalInset)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// The statistics alone, for a pane that scrolls them with its own content.
internal struct TableInfoSections: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    internal let metadata: TableMetadata
    internal var includesComment = true

    internal init(metadata: TableMetadata, includesComment: Bool = true) {
        self.metadata = metadata
        self.includesComment = includesComment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if includesComment, settingsManager.general.showObjectComments,
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("table-info")
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

    // The label takes what it needs and the value the rest, wrapping: labels are localized, so no fixed lane fits.
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
