//
//  TableInfoView.swift
//  TablePro
//

import SwiftUI

/// The table's own statistics, shown when the inspector has a table but no row selected.
///
/// A `Form` is right here and wrong for the field list: this has a dozen rows of fixed shape, so
/// eager layout costs nothing, and `.formStyle(.grouped)` gives the section headers and the value
/// wrapping the platform draws for a settings-shaped list.
///
/// Its headers are title case. They were hand-written in capitals ("SIZE", "STATISTICS"), which is
/// neither what `Form` draws nor what macOS has used since Big Sur.
internal struct TableInfoView: View {
    internal let metadata: TableMetadata

    var body: some View {
        Form {
            if AppSettingsManager.shared.general.showObjectComments,
               let comment = metadata.comment, !comment.isEmpty {
                Section(String(localized: "Comment")) {
                    Text(comment)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Section(String(localized: "Size")) {
                LabeledContent(String(localized: "Data"), value: TableMetadata.formatSize(metadata.dataSize))
                LabeledContent(String(localized: "Indexes"), value: TableMetadata.formatSize(metadata.indexSize))
                LabeledContent(String(localized: "Total"), value: TableMetadata.formatSize(metadata.totalSize))
            }

            if metadata.rowCount != nil || metadata.avgRowLength != nil {
                Section(String(localized: "Statistics")) {
                    if let rows = metadata.rowCount {
                        LabeledContent(String(localized: "Rows"), value: rows.formatted(.number))
                    }
                    if let averageLength = metadata.avgRowLength {
                        LabeledContent(
                            String(localized: "Average Row"),
                            value: TableMetadata.formatSize(averageLength)
                        )
                    }
                }
            }

            if metadata.engine != nil || metadata.collation != nil {
                Section(String(localized: "Metadata")) {
                    if let engine = metadata.engine {
                        LabeledContent(String(localized: "Engine"), value: engine)
                    }
                    if let collation = metadata.collation {
                        LabeledContent(String(localized: "Collation"), value: collation)
                            .help(collation)
                    }
                }
            }

            if metadata.createTime != nil || metadata.updateTime != nil {
                Section(String(localized: "Timestamps")) {
                    if let created = metadata.createTime {
                        LabeledContent(String(localized: "Created"), value: Self.date(created))
                    }
                    if let updated = metadata.updateTime {
                        LabeledContent(String(localized: "Updated"), value: Self.date(updated))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func date(_ value: Date) -> String {
        value.formatted(date: .numeric, time: .shortened)
    }
}
