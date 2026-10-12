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
    internal static var contestedMappingMessage: String {
        String(localized: "Each destination column can be mapped from only one source column.")
    }

    internal let tableName: String
    internal let sourceColumns: [String]
    internal let destinationColumns: [String]
    internal let onChange: ([String: String?]) -> Void
    internal let dismiss: () -> Void

    /// Held here rather than read back through the sheet: SwiftUI does not re-evaluate `.popover`
    /// content when the presenting view re-renders, so a pick that only wrote the sheet's state
    /// left this view drawing the mapping it opened with.
    @State private var overrides: [String: String?]

    internal init(
        tableName: String,
        sourceColumns: [String],
        destinationColumns: [String],
        overrides: [String: String?],
        onChange: @escaping ([String: String?]) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.tableName = tableName
        self.sourceColumns = sourceColumns
        self.destinationColumns = destinationColumns
        self.onChange = onChange
        self.dismiss = dismiss
        _overrides = State(initialValue: overrides)
    }

    private var resolved: TableColumnMatcher.Match {
        TableColumnMatcher.match(
            source: sourceColumns, destination: destinationColumns, overrides: overrides)
    }

    internal var body: some View {
        let match = resolved
        let contested = Set(match.contestedDestinations)
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
                        row(for: column, isContested: match.mapping[column].map(contested.contains) ?? false)
                    }
                }
            }
            .frame(height: 200)

            if !contested.isEmpty {
                Text(Self.contestedMappingMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !match.unmatchedDestination.isEmpty {
                Text(unmatchedDestinationLabel(match.unmatchedDestination))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Match by Name") { update([:]) }
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func row(for column: String, isContested: Bool) -> some View {
        HStack(spacing: 6) {
            Text(column)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 130, alignment: .leading)

            Picker(String(format: String(localized: "Destination for %@"), column),
                   selection: binding(for: column)) {
                Text("Skip").tag(String?.none)
                ForEach(destinationColumns, id: \.self) { target in
                    Text(target).tag(String?.some(target))
                }
            }
            .labelsHidden()
            .frame(width: 150)

            if isContested {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(String(localized: "Another source column is mapped to the same destination column."))
                    .accessibilityLabel(
                        Text("Another source column is mapped to the same destination column."))
            }
        }
    }

    /// A destination column nothing writes to takes its own default or null, which only fails when
    /// it is `NOT NULL` without one, so it is stated rather than blocked.
    private func unmatchedDestinationLabel(_ columns: [String]) -> String {
        String(
            format: String(localized: "Not written: %@. Each takes its default or null."),
            columns.joined(separator: ", ")
        )
    }

    private func binding(for column: String) -> Binding<String?> {
        Binding(
            get: { resolved.mapping[column] },
            set: { target in
                var updated = overrides
                updated[column] = .some(target)
                update(updated)
            }
        )
    }

    private func update(_ updated: [String: String?]) {
        overrides = updated
        onChange(updated)
    }
}
