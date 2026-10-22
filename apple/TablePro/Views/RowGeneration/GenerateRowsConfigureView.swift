//
//  GenerateRowsConfigureView.swift
//  TablePro
//

import SwiftUI

internal struct GenerateRowsConfigureView: View {
    @ObservedObject internal var session: RowGenerationSession

    internal var body: some View {
        VStack(spacing: 0) {
            runSettings
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                GenerateRowsColumnList(session: session)
                    .frame(width: 260)
                Divider()
                if let column = session.selectedColumn {
                    GenerateRowsColumnOptions(session: session, column: column)
                        .id(column.name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(String(localized: "Select a column"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            GenerateRowsPreviewView(session: session)
                .frame(height: 170)
        }
    }

    private var runSettings: some View {
        HStack(spacing: 24) {
            HStack(spacing: 8) {
                Text(String(localized: "Rows"))
                TextField(String(localized: "Rows"), value: $session.settings.rowCount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 110)
                    .accessibilityLabel(String(localized: "Rows"))
                    .accessibilityIdentifier("generate-rows-count")
            }
            HStack(spacing: 8) {
                Text(String(localized: "Seed"))
                TextField(String(localized: "Seed"), value: $session.settings.seed, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 110)
                    .accessibilityLabel(String(localized: "Seed"))
                    .accessibilityIdentifier("generate-rows-seed")
                Button {
                    session.shuffleSeed()
                } label: {
                    Image(systemName: "shuffle")
                }
                .help(String(localized: "New Seed"))
                .accessibilityLabel(String(localized: "New Seed"))
            }
            Text(String(localized: "The same seed and settings give the same rows."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

internal struct GenerateRowsColumnList: View {
    @ObservedObject internal var session: RowGenerationSession

    internal var body: some View {
        let issueColumns = Set(session.issues.compactMap(\.column))
        List(selection: $session.selectedColumnName) {
            ForEach(session.table?.columns ?? []) { column in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(column.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(session.columnSettings(column.name)?.kind.title ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if issueColumns.contains(column.name) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(String(localized: "Needs attention"))
                    }
                }
                .tag(column.name)
                .accessibilityElement(children: .combine)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("generate-rows-columns")
    }
}
