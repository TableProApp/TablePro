//
//  ExportRowScopeEditor.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Narrows one table's rows and columns without leaving the export tree.
///
/// The filter is the engine's own SQL, so it is not validated here beyond refusing a second
/// statement: an expression this dialog rejected would have to be a dialect check for every engine
/// TablePro speaks, and the server's own error is a better one than any of them.
internal struct ExportRowScopeEditor: View {
    internal let objectName: String
    internal let availableColumns: [String]
    @Binding internal var scope: PluginExportRowScope
    internal let dismiss: () -> Void

    @State private var filter: String = ""
    @State private var rowLimitText: String = ""
    @State private var selectedColumns: Set<String> = []

    private var hasRejectedFilter: Bool {
        PluginExportRowScope(filter: filter).hasRejectedFilter
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(objectName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 4) {
                Text("Where")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("status = 'active'", text: $filter, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2 ... 4)
                    .font(ThemeEngine.shared.valueFontSwiftUI)
                if hasRejectedFilter {
                    Text("A filter is one expression. Remove the semicolon.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Row limit")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("All rows", text: $rowLimitText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onChange(of: rowLimitText) { _, entered in
                        let digits = entered.filter(\.isWholeNumber)
                        if digits != entered { rowLimitText = digits }
                    }
            }

            if !availableColumns.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Columns")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Select All") { selectedColumns = [] }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(selectedColumns.isEmpty)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(availableColumns, id: \.self) { column in
                                Toggle(column, isOn: binding(for: column))
                                    .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    Text("Every column is written when none is ticked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Clear") {
                    filter = ""
                    rowLimitText = ""
                    selectedColumns = []
                    commit()
                }
                Spacer()
                Button("Done") {
                    commit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            filter = scope.filter
            rowLimitText = scope.rowLimit.map(String.init) ?? ""
            selectedColumns = Set(scope.columns)
        }
        .onDisappear(perform: commit)
    }

    /// An unticked column set means every column, so a set covering all of them is stored empty:
    /// otherwise a later schema change would silently drop a column the user never excluded.
    private func binding(for column: String) -> Binding<Bool> {
        Binding(
            get: { selectedColumns.isEmpty || selectedColumns.contains(column) },
            set: { isOn in
                var updated = selectedColumns.isEmpty ? Set(availableColumns) : selectedColumns
                if isOn {
                    updated.insert(column)
                } else {
                    updated.remove(column)
                }
                selectedColumns = updated.count == availableColumns.count ? [] : updated
            }
        )
    }

    private func commit() {
        let trimmedLimit = rowLimitText.trimmingCharacters(in: .whitespaces)
        let limit = Int(trimmedLimit).flatMap { $0 > 0 ? $0 : nil }
        /// The column list is read on demand and a failed read comes back empty, which cannot be
        /// told apart here from a table with no columns. Deriving the set from it either way threw
        /// away a column subset the user had already saved.
        guard !availableColumns.isEmpty else {
            scope = PluginExportRowScope(filter: filter, rowLimit: limit, columns: scope.columns)
            return
        }
        scope = PluginExportRowScope(
            filter: filter,
            rowLimit: limit,
            columns: availableColumns.filter { selectedColumns.contains($0) }
        )
    }
}
