//
//  TablePropertiesView.swift
//  TablePro
//

import SwiftUI

/// The table's own identity, its driver-supplied properties, and its comment.
///
/// The comment is the only editable field, and it stages into the same `StructureChangeManager` the
/// Columns grid writes to, so it saves, discards and undoes through the controls the rest of the
/// Structure tab already uses.
struct TablePropertiesView: View {
    let tableName: String
    let schemaName: String?
    let databaseName: String
    let metadata: TableMetadata?
    let loadError: String?
    let isLoading: Bool
    let isView: Bool
    let isCommentEditable: Bool
    let comment: String
    let onCommentChange: (String) -> Void

    private var themeEngine: ThemeEngine { ThemeEngine.shared }

    var body: some View {
        if let loadError, metadata == nil {
            ContentUnavailableView(
                String(localized: "Properties Unavailable"),
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading, metadata == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Name"), value: tableName)
                if let schemaName, !schemaName.isEmpty {
                    LabeledContent(String(localized: "Schema"), value: schemaName)
                }
                if !databaseName.isEmpty {
                    LabeledContent(String(localized: "Database"), value: databaseName)
                }
                ForEach(metadata?.attributes ?? []) { attribute in
                    LabeledContent(attribute.label, value: attribute.value)
                }
            } header: {
                Text("GENERAL")
            }

            commentSection

            if let metadata {
                statisticsSection(metadata)
                storageSection(metadata)
                timestampsSection(metadata)
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }

    /// A comment the engine cannot store, and an empty one, are the same absence, so the read-only
    /// case falls back to a line of text rather than an empty box nothing can ever fill.
    @ViewBuilder
    private var commentSection: some View {
        Section {
            if !isCommentEditable, comment.isEmpty {
                Text(unavailableCommentMessage)
                    .foregroundStyle(.secondary)
            } else {
                TextValueEditor(
                    text: Binding(get: { comment }, set: onCommentChange),
                    isEditable: isCommentEditable,
                    font: themeEngine.valueFont,
                    borderType: .bezelBorder
                )
                .frame(minHeight: 140)
                .accessibilityIdentifier("table-comment-editor")
                .accessibilityLabel(Text("Table comment"))
            }
        } header: {
            Text("COMMENT")
        }
    }

    /// Two different absences. The engine has no comment to store at all, or it has one for tables
    /// and spells this relation's with a keyword the structure editor cannot ask for.
    private var unavailableCommentMessage: String {
        isView || metadata?.commentIsReadOnly == true
            ? String(localized: "This object's comment is read-only. Run COMMENT ON in the editor to change it.")
            : String(localized: "This database does not store a comment on a table.")
    }

    @ViewBuilder
    private func statisticsSection(_ metadata: TableMetadata) -> some View {
        if metadata.rowCount != nil || metadata.avgRowLength != nil {
            Section {
                if let rows = metadata.rowCount {
                    LabeledContent(String(localized: "Rows"), value: rows.formatted())
                }
                if let avgLength = metadata.avgRowLength {
                    LabeledContent(
                        String(localized: "Avg Row"),
                        value: TableMetadata.formatSize(avgLength))
                }
            } header: {
                Text("STATISTICS")
            }
        }
    }

    @ViewBuilder
    private func storageSection(_ metadata: TableMetadata) -> some View {
        Section {
            LabeledContent(
                String(localized: "Data Size"),
                value: TableMetadata.formatSize(metadata.dataSize))
            LabeledContent(
                String(localized: "Index Size"),
                value: TableMetadata.formatSize(metadata.indexSize))
            LabeledContent(
                String(localized: "Total Size"),
                value: TableMetadata.formatSize(metadata.totalSize))
            if let engine = metadata.engine {
                LabeledContent(String(localized: "Engine"), value: engine)
            }
            if let collation = metadata.collation {
                LabeledContent(String(localized: "Collation"), value: collation)
                    .help(collation)
            }
        } header: {
            Text("STORAGE")
        }
    }

    @ViewBuilder
    private func timestampsSection(_ metadata: TableMetadata) -> some View {
        if metadata.createTime != nil || metadata.updateTime != nil {
            Section {
                if let created = metadata.createTime {
                    LabeledContent(
                        String(localized: "Created"),
                        value: created.formatted(date: .numeric, time: .shortened))
                }
                if let updated = metadata.updateTime {
                    LabeledContent(
                        String(localized: "Updated"),
                        value: updated.formatted(date: .numeric, time: .shortened))
                }
            } header: {
                Text("TIMESTAMPS")
            }
        }
    }
}
