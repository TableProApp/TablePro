//
//  TableTransferMappingEditor.swift
//  TablePro
//

import SwiftUI

/// Repoints or excludes one table's columns before a transfer runs.
///
/// Columns are matched by name to begin with, which is right almost always and wrong exactly when
/// the two schemas were renamed apart. Without this the only way to correct that would be to rename
/// a column on one side.
internal struct TableTransferMappingEditor: View {
    internal let tableName: String
    internal let sourceColumns: [String]
    internal let destinationColumns: [String]
    @Binding internal var overrides: [String: String?]
    internal let dismiss: () -> Void

    private var automatic: TableColumnMatcher.Match {
        TableColumnMatcher.match(source: sourceColumns, destination: destinationColumns)
    }

    private var resolved: TableColumnMatcher.Match {
        overrides.isEmpty
            ? automatic
            : TableColumnMatcher.applying(
                overrides: overrides, to: automatic, destination: destinationColumns)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tableName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("Source column on the left, destination on the right.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sourceColumns, id: \.self) { column in
                        HStack(spacing: 6) {
                            Text(column)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 130, alignment: .leading)

                            Picker("", selection: binding(for: column)) {
                                Text("Skip").tag(String?.none)
                                ForEach(destinationColumns, id: \.self) { target in
                                    Text(target).tag(String?.some(target))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                    }
                }
            }
            .frame(height: 200)

            if !resolved.unmatchedDestination.isEmpty {
                Text(unmatchedDestinationLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Match by Name") { overrides = [:] }
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    /// A destination column nothing writes to takes its own default or null, which only fails when
    /// it is `NOT NULL` without one, so it is stated rather than blocked.
    private var unmatchedDestinationLabel: String {
        String(
            format: String(localized: "Not written: %@. Each takes its default or null."),
            resolved.unmatchedDestination.joined(separator: ", ")
        )
    }

    private func binding(for column: String) -> Binding<String?> {
        Binding(
            get: { resolved.mapping[column] },
            set: { overrides[column] = .some($0) }
        )
    }
}
