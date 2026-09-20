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
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let scope: DatabaseScope
    let databaseType: DatabaseType
    let fkInfo: ForeignKeyInfo
    let currentValue: String?
    let isNullable: Bool
    let onCommit: (String?) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var columns: [ForeignKeyLookupColumn] = []
    @State private var labelChoice: ForeignKeyLabelChoice = .unset
    @State private var isChoosingLabels = false
    @State private var rows: [ForeignKeyLookupService.Row] = []
    @State private var isLoading = true
    @State private var hasLoadedColumns = false
    @State private var hasSearched = false
    @State private var termIsNotSearchable = false
    @State private var errorMessage: String?
    @State private var selection: ForeignKeyPickerEntry.ID?

    private static let logger = Logger(subsystem: "com.TablePro", category: "ForeignKeyPicker")
    private static let searchDebounce = Duration.milliseconds(200)
    private static let listHeight: CGFloat = 220

    var body: some View {
        Group {
            if isChoosingLabels {
                labelChooser
            } else {
                picker
            }
        }
        .frame(width: 360)
        .task {
            await loadColumns()
        }
        .task(id: SearchKey(term: searchText, labels: labelColumnNames, isReady: hasLoadedColumns)) {
            await runSearch()
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            content
            Divider()
            footer
        }
    }

    /// Drilled in to rather than opened beside: the HIG rules out both a second popover over a
    /// popover and a sheet over one, and no macOS menu stays open past a single tick, so a menu of
    /// checkmarks would cost one reopen per column chosen.
    private var labelChooser: some View {
        ForeignKeyLabelChooserView(
            columns: selectableColumns,
            selectedNames: labelColumnNames,
            listHeight: Self.listHeight,
            onToggle: toggleLabelColumn,
            onClear: { applyLabelChoice(ForeignKeyLabelChoice(columnNames: [])) },
            onDone: { withAnimation { isChoosingLabels = false } }
        )
    }

    // MARK: - Header

    /// An engine with schemas qualifies by schema as it always has. One without has no schema to
    /// show, and naming the referenced database only says something when it is not the database the
    /// reader is already looking at: every MySQL reference carries one, so spelling it out
    /// unconditionally put `shop.users` in front of someone browsing `shop`.
    private var referencedTableDisplay: String {
        let target = targetScope
        if let schema = target.schema {
            return "\(schema).\(fkInfo.referencedTable)"
        }
        guard target.database != scope.database, !target.database.isEmpty else {
            return fkInfo.referencedTable
        }
        return "\(target.database).\(fkInfo.referencedTable)"
    }

    private var targetScope: DatabaseScope {
        ForeignKeyLookupService.targetScope(from: scope, databaseType: databaseType, reference: fkInfo)
    }

    private var referencedTableScope: TableScope {
        ForeignKeyLookupService.tableScope(from: scope, databaseType: databaseType, reference: fkInfo)
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
            RevealedTextView(errorMessage)
                .foregroundStyle(.red)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .frame(height: Self.listHeight)
        } else if entries.isEmpty {
            emptyState
        } else {
            entryList
        }
    }

    /// A term no selected column can hold is not a term that matched nothing. Reporting the two the
    /// same way made a picker on a numeric key with a numeric label answer "No matching rows" to
    /// every word while still answering a number, which reads as a search that half works.
    ///
    /// A search in flight outranks both, because the answer belongs to the term that produced it:
    /// clearing an unsearchable term left "No text column to search" standing over the full list
    /// it was already fetching.
    @ViewBuilder
    private var emptyState: some View {
        Group {
            if isLoading {
                Text("Loading rows…")
            } else if termIsNotSearchable {
                Text("No text column to search")
            } else {
                Text("No matching rows")
            }
        }
        .foregroundStyle(.secondary)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: Self.listHeight)
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            List(entries, selection: $selection) { entry in
                row(for: entry)
                    .contentShape(Rectangle())
                    .onTapGesture { commit(entry) }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { commit(entry) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: Self.listHeight)
            .onChange(of: selection) { newValue in
                guard let newValue else { return }
                proxy.scrollTo(newValue)
            }
        }
    }

    /// Both the key and the label are stored values, so both wear the Data Grid Font rather than a
    /// system text style: one value has to read the same here as it does in the cell it is about
    /// to fill.
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
                    .font(themeEngine.valueFontSwiftUI)
                    .lineLimit(1)
                if let label = ForeignKeyLabelText.joined(row.labels) {
                    Text(label)
                        .font(themeEngine.valueFontSwiftUI)
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
            Button {
                withAnimation { isChoosingLabels = true }
            } label: {
                Text(String(format: String(localized: "Label: %@"), labelSummary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .disabled(selectableColumns.isEmpty)
            .help(String(localized: "Choose the columns shown beside each key"))
            .accessibilityIdentifier("fk-picker-label")

            Spacer(minLength: 4)

            if isCapped {
                Text(String(format: String(localized: "First %d"), ForeignKeyLookupQuery.rowLimit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }

            if isNullable {
                Button {
                    onCommit(nil)
                    onDismiss()
                } label: {
                    Text("Set NULL")
                }
                .controlSize(.small)
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var isCapped: Bool {
        rows.count >= ForeignKeyLookupQuery.rowLimit
    }

    private var labelSummary: String {
        let names = labelColumnNames
        guard !names.isEmpty else { return String(localized: "None") }
        return names.joined(separator: ForeignKeyLabelText.separator)
    }

    // MARK: - Label columns

    private var selectableColumns: [ForeignKeyLookupColumn] {
        ForeignKeyLabelColumn.selectable(columns, keyColumn: fkInfo.referencedColumn)
    }

    private var labelColumns: [ForeignKeyLookupColumn] {
        ForeignKeyLabelColumn.resolve(
            columns: columns,
            keyColumn: fkInfo.referencedColumn,
            choice: labelChoice
        )
    }

    private var labelColumnNames: [String] {
        labelColumns.map(\.name)
    }

    /// Toggling starts from what is on screen, so the first tick over a heuristic label keeps that
    /// label rather than replacing it, and clearing the last one is remembered as **None** rather
    /// than as no answer: storing it as absence let the heuristic pick a label again on the next
    /// open.
    private func toggleLabelColumn(_ name: String) {
        var names = labelColumnNames
        if let index = names.firstIndex(of: name) {
            names.remove(at: index)
        } else {
            names.append(name)
        }
        applyLabelChoice(ForeignKeyLabelChoice(columnNames: names))
    }

    private func applyLabelChoice(_ choice: ForeignKeyLabelChoice) {
        labelChoice = choice
        ForeignKeyLabelColumnStore.shared.setLabelChoice(choice, for: referencedTableScope)
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
            let fetched = try await ForeignKeyLookupService.referencedColumns(
                in: scope, databaseType: databaseType, reference: fkInfo
            )
            guard !Task.isCancelled else { return }
            labelChoice = ForeignKeyLabelColumnStore.shared.labelChoice(for: referencedTableScope)
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
        isLoading = true
        termIsNotSearchable = false
        errorMessage = nil

        if hasSearched {
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
        }

        do {
            let outcome = try await ForeignKeyLookupService.search(
                in: scope,
                databaseType: databaseType,
                reference: fkInfo,
                key: key,
                labels: labelColumns,
                term: searchText
            )
            guard !Task.isCancelled else { return }
            switch outcome {
            case .rows(let found):
                rows = found
            case .termNotSearchable:
                rows = []
                termIsNotSearchable = true
            }
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
    let labels: [String]
    let isReady: Bool
}
