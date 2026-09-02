//
//  ForeignKeyPickerView.swift
//  TablePro
//
//  The value picker a foreign key cell opens instead of the plain text editor.
//

import os
import SwiftUI
import TableProPluginKit

struct ForeignKeyPickerView: View {
    let scope: DatabaseScope
    let databaseType: DatabaseType
    let fkInfo: ForeignKeyInfo
    let currentValue: String?
    let isNullable: Bool
    let onCommit: (String?) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var columns: [ForeignKeyLookupColumn] = []
    @State private var labelColumnName: String?
    @State private var rows: [ForeignKeyLookupService.Row] = []
    @State private var isLoading = true
    @State private var hasLoadedColumns = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var selection: ForeignKeyPickerEntry.ID?

    private static let logger = Logger(subsystem: "com.TablePro", category: "ForeignKeyPicker")
    private static let searchDebounce = Duration.milliseconds(200)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .task {
            await loadColumns()
        }
        .task(id: SearchKey(term: searchText, label: labelColumnName, isReady: hasLoadedColumns)) {
            await runSearch()
        }
    }

    // MARK: - Header

    private var referencedTableDisplay: String {
        guard let schema = fkInfo.referencedSchema, !schema.isEmpty else { return fkInfo.referencedTable }
        return "\(schema).\(fkInfo.referencedTable)"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(fkInfo.column) → \(referencedTableDisplay).\(fkInfo.referencedColumn)")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Search

    private var searchField: some View {
        NativeSearchField(
            text: $searchText,
            placeholder: String(format: String(localized: "Search %@"), fkInfo.referencedTable),
            onMoveUp: { moveSelection(by: -1) },
            onMoveDown: { moveSelection(by: 1) },
            onSubmit: commitSelection,
            focusOnAppear: true,
            accessibilityIdentifier: "fk-picker-search"
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .frame(height: 220)
        } else if entries.isEmpty {
            emptyState
        } else {
            entryList
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if hasSearched {
                Text("No matching rows")
            } else {
                Text("Loading rows…")
            }
        }
        .foregroundStyle(.secondary)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 220)
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            List(entries, selection: $selection) { entry in
                row(for: entry)
                    .contentShape(Rectangle())
                    .onTapGesture { commit(entry) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 220)
            .onChange(of: selection) { _, newValue in
                guard let newValue else { return }
                proxy.scrollTo(newValue)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: ForeignKeyPickerEntry) -> some View {
        switch entry {
        case .literal(let text):
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
                Text(String(format: String(localized: "Use “%@”"), text))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .row(let row):
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .opacity(row.key == currentValue ? 1 : 0)
                Text(row.key)
                    .font(ThemeEngine.shared.valueFontSwiftUI)
                    .lineLimit(1)
                if let label = row.label, !label.isEmpty {
                    Text(label)
                        .font(ThemeEngine.shared.valueFontSwiftUI)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Picker(selection: labelBinding) {
                Text("None").tag(String?.none)
                ForEach(columns) { column in
                    Text(column.name).tag(String?.some(column.name))
                }
            } label: {
                Text("Label")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(columns.isEmpty)

            Spacer(minLength: 4)

            if isCapped {
                Text(String(format: String(localized: "First %d"), ForeignKeyLookupQuery.rowLimit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isNullable {
                Button {
                    onCommit(nil)
                    onDismiss()
                } label: {
                    Text("Set NULL")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var isCapped: Bool {
        rows.count >= ForeignKeyLookupQuery.rowLimit
    }

    private var labelBinding: Binding<String?> {
        Binding(
            get: { labelColumnName },
            set: { newValue in
                labelColumnName = newValue
                ForeignKeyLabelColumnStore.shared.setLabelColumn(
                    newValue,
                    for: ForeignKeyLookupService.tableScope(from: scope, reference: fkInfo)
                )
            }
        )
    }

    // MARK: - Entries

    private var keyColumn: ForeignKeyLookupColumn? {
        columns.first { $0.name == fkInfo.referencedColumn }
    }

    private var entries: [ForeignKeyPickerEntry] {
        ForeignKeyPickerEntry.build(rows: rows, term: searchText, keyType: keyColumn?.type)
    }

    /// Return commits whatever the list has selected, which `defaultSelection` puts on the typed
    /// term when the term could be a key and on the matching row when it could not. A selection
    /// belongs to the results it was computed from, so typing drops it before the debounce even
    /// starts: `Return` during an in-flight search must never commit the row the last one found.
    ///
    /// The fallback covers a term that matched nothing at all, and applies the same rule: a word on
    /// a numeric key is a search that failed, not a value to write.
    private func commitSelection() {
        if let selection, let entry = entries.first(where: { $0.id == selection }) {
            commit(entry)
            return
        }
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty,
              ForeignKeyPickerEntry.acceptsTypedKey(term, keyType: keyColumn?.type) else { return }
        onCommit(term)
        onDismiss()
    }

    private func commit(_ entry: ForeignKeyPickerEntry) {
        onCommit(entry.committedValue)
        onDismiss()
    }

    private func moveSelection(by offset: Int) {
        let available = entries
        guard !available.isEmpty else { return }
        guard let selection, let index = available.firstIndex(where: { $0.id == selection }) else {
            self.selection = offset > 0 ? available.first?.id : available.last?.id
            return
        }
        let target = index + offset
        guard available.indices.contains(target) else { return }
        self.selection = available[target].id
    }

    // MARK: - Loading

    private func loadColumns() async {
        do {
            let fetched = try await ForeignKeyLookupService.referencedColumns(in: scope, reference: fkInfo)
            guard !Task.isCancelled else { return }
            let stored = ForeignKeyLabelColumnStore.shared.labelColumn(
                for: ForeignKeyLookupService.tableScope(from: scope, reference: fkInfo)
            )
            labelColumnName = ForeignKeyLabelColumn.resolve(
                columns: fetched,
                keyColumn: fkInfo.referencedColumn,
                preferred: stored
            )?.name
            columns = fetched
            hasLoadedColumns = true
        } catch {
            Self.logger.error("Referenced column read failed: \(error.localizedDescription)")
            isLoading = false
            errorMessage = String(localized: "Could not read the referenced table")
        }
    }

    private func runSearch() async {
        guard hasLoadedColumns else { return }
        guard let key = keyColumn else {
            isLoading = false
            hasSearched = true
            errorMessage = String(
                format: String(localized: "%@ has no column named %@"),
                referencedTableDisplay,
                fkInfo.referencedColumn
            )
            return
        }

        selection = nil

        if hasSearched {
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
        }

        isLoading = true
        errorMessage = nil
        do {
            let found = try await ForeignKeyLookupService.search(
                in: scope,
                databaseType: databaseType,
                reference: fkInfo,
                key: key,
                label: columns.first { $0.name == labelColumnName },
                term: searchText
            )
            guard !Task.isCancelled else { return }
            rows = found
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("Foreign key row search failed: \(error.localizedDescription)")
            rows = []
            errorMessage = String(localized: "Could not search the referenced table")
        }
        isLoading = false
        hasSearched = true
        selection = ForeignKeyPickerEntry.defaultSelection(
            in: entries,
            term: searchText,
            currentValue: currentValue
        )
    }
}

private struct SearchKey: Equatable {
    let term: String
    let label: String?
    let isReady: Bool
}
