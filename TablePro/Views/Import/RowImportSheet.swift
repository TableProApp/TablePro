//
//  RowImportSheet.swift
//  TablePro
//
//  Import sheet for row-based formats (JSON, NDJSON, CSV): map each source
//  field to a column in an existing table, or create a new table with columns
//  inferred from the data. The format plugin supplies the icon, name, and the
//  field-detection options shown in this sheet.
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit

struct RowImportSheet: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    private static let logger = Logger(subsystem: "com.TablePro", category: "RowImportSheet")

    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let fileURL: URL
    /// What the sheet, the proposed table name, the error report and history call the source.
    /// It differs from `fileURL` when the rows arrive through a snapshot the app wrote.
    let sourceName: String
    let formatId: String

    private enum Destination: Hashable {
        case existingTable
        case newTable
    }

    /// The identity of a read. `.task(id:)` cancels the read in flight when it changes.
    private struct SourceRead: Hashable {
        let destination: Destination
        let scope: DatabaseScope?
        let table: String?
        let signature: String
        let attempt: Int
    }

    private struct ImportPlan {
        let targetTable: String
        let fields: [String]
        let columns: [String]
        let columnMapping: [String: String]
        let newTable: PluginCreateTableDefinition?
    }

    @State private var destination: Destination = .existingTable

    /// The database and schema every read and write of this sheet goes to: where the connection was
    /// browsing when the sheet opened. The sheet is modal to its window, but another window on the
    /// same connection, or an MCP client, can move the browse database while it is open. Resolving
    /// it again at each step listed one database's tables and mapped one table's columns, then
    /// created, cleared and filled tables in another. Nil only while the connection has no session,
    /// and taken once one exists.
    @State private var scope: DatabaseScope?

    /// Every object the connection holds, not just the tables the destination picker offers. A
    /// `CREATE TABLE` collides with a view, a materialized view or a foreign table under the same
    /// name as surely as with a table, so the name check has to see all of them.
    @State private var databaseObjects: [TableInfo] = []

    /// Those names folded for comparison, and `nil` while the catalog is unknown. A read that
    /// failed leaves an empty list, and taking that for "nothing is in the way" would propose a
    /// name that already exists and then report it as free. Stored rather than computed because the
    /// name check runs on every keystroke, and `body` would otherwise rebuild the set each time.
    @State private var catalogNameKeys: Set<String>?
    @State private var tableListError: String?

    /// `loadTables()` is `@MainActor` but reentrant across its `await`, so two Try Again presses
    /// would interleave and a late failure could clear the keys while the picker kept its rows.
    /// Concurrent callers wait for the one in flight, per the schema-loading invariant.
    @State private var isLoadingTables = false
    @State private var selectedTargetTable: String?
    @StateObject private var mapping = RowImportMapping()
    @State private var newTableName: String = ""

    /// The last name this sheet proposed, so a second pass can tell its own guess from what
    /// the user typed over it.
    @State private var proposedTableName: String = ""
    @State private var newTable = NewTableDraft()
    @State private var isLoadingContext = false

    /// Copied from the plugin, whose options are edited in its own view that this sheet does not observe.
    @State private var detectionSignature = ""
    @State private var readAttempts: [Destination: Int] = [:]
    @State private var lastNewColumnsRead: SourceRead?
    @State private var loadError: String?

    /// Moving focus here also selects the whole proposed name, measured rather than assumed:
    /// SwiftUI hands the field editor a full selection when `@FocusState` lands on text already in
    /// place, both on appear and when the field is revealed by the destination picker. So the first
    /// keystroke replaces the proposal instead of appending to it, and no AppKit detour is needed.
    @FocusState private var newTableNameFocused: Bool

    /// The plugin's own options are persistent and shared, and this sheet edits them in place.
    /// Without a snapshot, Cancel kept every change, so `Delete existing rows` stayed armed for
    /// the next import from anywhere in the app.
    @State private var settingsSnapshot: PluginSettingsSnapshot?
    @State private var importSucceeded = false

    @State private var importService: ImportService?
    @State private var importResult: PluginImportResult?
    @State private var importedRows: DatabaseObjectChange?
    @State private var importError: (any Error)?
    @State private var showProgressDialog = false
    @State private var showSuccessDialog = false
    @State private var showErrorDialog = false
    @State private var importTask: Task<Void, Never>?

    /// Knows the tables this sheet created. A failed import leaves its table behind, so a retry has to
    /// know it already owns that table rather than trying to create it a second time and failing on
    /// the name.
    @State private var newTablePlanner = NewTableImportPlanner()

    /// The window this sheet is hosted in, used for presenting its alerts.
    /// Avoids `NSApp.keyWindow`, which when a result is presented is the progress sheet being
    /// torn down in the same transaction, and AppKit ends a sheet's children with it (#2314).
    @State private var hostWindow: NSWindow?

    init(
        isPresented: Binding<Bool>,
        connection: DatabaseConnection,
        fileURL: URL,
        sourceName: String,
        formatId: String
    ) {
        _isPresented = isPresented
        self.connection = connection
        self.fileURL = fileURL
        self.sourceName = sourceName
        self.formatId = formatId
        _scope = State(initialValue: DatabaseManager.shared.browseScope(for: connection.id))
    }

    // MARK: - Derived catalog state

    /// Tables alone, because they are the only objects the existing-table branch can insert into.
    /// A partitioned table is one of them: the server routes an INSERT to the right partition.
    private var availableTables: [TableInfo] {
        databaseObjects.filter(\.type.acceptsImportedRows)
    }

    /// A table this sheet created is not in the way of this sheet: a failed import leaves its table
    /// behind, and `NewTableImportPlanner` exists to reuse that one on the retry, so reporting the
    /// name as taken would block the very attempt that mechanism exists to allow. Asked of the
    /// planner rather than folded into `catalogNameKeys`, which is rebuilt only when the catalog is.
    private var newTableNameProblem: NewTableNameProblem? {
        let trimmed = newTableName.trimmingCharacters(in: .whitespaces)
        let problem = NewTableNaming.problem(
            with: newTableName,
            style: NewTableNameStyle.forDatabaseType(connection.type),
            existingNames: catalogNameKeys
        )
        guard problem == .nameTaken, let scope, newTablePlanner.created(TableScope(table: trimmed, in: scope)) else {
            return problem
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding()
            Divider()

            destinationForm
                .padding(.horizontal)
                .padding(.vertical, 10)
            Divider()

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()

            optionsForm
                .padding(.horizontal)
                .padding(.vertical, 10)
            Divider()

            footerView
                .padding()
        }
        .frame(minWidth: 720, minHeight: 560, idealHeight: 640, maxHeight: .infinity)
        .background {
            WindowAccessor { window in
                hostWindow = window
            }
        }
        .background { detectionSignatureObserver }
        .task {
            settingsSnapshot = PluginSettingsSnapshot(
                plugins: [currentPlugin as? any SettablePluginDiscoverable].compactMap { $0 })
            suggestNewTableName()
            await loadTables()
        }
        .task(id: sourceRead) {
            await read(sourceRead)
        }
        .onChange(of: destination) { newValue in
            guard newValue == .newTable else { return }
            suggestNewTableName()
            newTableNameFocused = true
        }
        .onChange(of: selectedTargetTable) { _ in
            mapping.clear()
        }
        .onChange(of: currentPlugin?.fieldDetectionSignature) { newValue in
            detectionSignature = newValue ?? ""
        }
        .onDisappear {
            importTask?.cancel()
            if !importSucceeded { settingsSnapshot?.restore() }
            settingsSnapshot = nil
        }
        .sheet(isPresented: $showProgressDialog) {
            if let service = importService {
                ImportProgressView(service: service) { service.cancelImport() }
                    .interactiveDismissDisabled()
            }
        }
        .onChange(of: showSuccessDialog) { isShowing in
            guard isShowing else { return }
            TransferResultAlert.presentImportSuccess(
                result: importResult,
                window: hostWindow,
                sourceFileName: sourceName,
                targetTable: selectedTargetTable
            ) {
                showSuccessDialog = false
                isPresented = false
                if let importedRows {
                    AppCommands.shared.objectChanged.send(importedRows)
                }
            }
        }
        .onChange(of: showErrorDialog) { isShowing in
            guard isShowing else { return }
            TransferResultAlert.presentImportFailure(error: importError, window: hostWindow) {
                showErrorDialog = false
            }
        }
    }

    // MARK: - Header / forms

    private var headerView: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: currentPlugin.map { type(of: $0).iconName } ?? "tablecells")
                .font(.title)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceName)
                    .font(.headline)
                Text("Import rows into a table")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoadingContext {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var destinationForm: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                Text("Destination:")
                    .gridColumnAlignment(.trailing)
                Picker(String(localized: "Destination"), selection: $destination) {
                    Text("Existing table").tag(Destination.existingTable)
                    Text("New table").tag(Destination.newTable)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if destination == .existingTable {
                GridRow {
                    Text("Import into:")
                    Picker(String(localized: "Import into"), selection: $selectedTargetTable) {
                        Text("Select a table…").tag(String?.none)
                        ForEach(availableTables, id: \.id) { table in
                            Text(table.name).tag(String?.some(table.name))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                }
            } else {
                GridRow {
                    Text("New table:")
                    TextField("", text: $newTableName, prompt: Text("table_name"))
                        .frame(maxWidth: 280)
                        .focused($newTableNameFocused)
                        .accessibilityLabel(String(localized: "New table"))
                }
            }

            if let tableListError {
                GridRow {
                    tableListErrorRow(tableListError)
                        .gridCellColumns(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The list is what both destinations are chosen against, so a failure to read it is worth
    /// saying and worth being able to retry without losing the options already set in this sheet.
    private func tableListErrorRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Label(
                String(format: String(localized: "Could not read the table list. %@"), message),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            Button(String(localized: "Try Again")) {
                Task { await loadTables() }
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(isLoadingTables)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionsForm: some View {
        Group {
            if let settable = currentPlugin as? any SettablePluginDiscoverable,
               let optionsView = settable.settingsView() {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Options").font(.callout.weight(.semibold))
                    optionsView
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footerView: some View {
        DialogFooter {
            if let message = validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        } actions: {
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Import") { performImport() }
                .buttonStyle(.borderedProminent)
                .disabled(!canImport)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Content tables

    @ViewBuilder
    private var contentArea: some View {
        if let loadError {
            unreadableFile(reason: loadError)
        } else {
            switch destination {
            case .existingTable:
                if selectedTargetTable == nil {
                    placeholder("Choose a destination table to map fields.")
                } else if mapping.rows.isEmpty {
                    placeholder(currentReadHasLanded ? "No fields found in the file." : readingPlaceholder)
                } else {
                    mappingTable
                }
            case .newTable:
                if newTable.columns.isEmpty {
                    placeholder(currentReadHasLanded ? "No columns found in the file." : readingPlaceholder)
                } else {
                    newColumnsTable
                }
            }
        }
    }

    /// A read takes seconds on a large file, and until it lands the list is empty, which the other
    /// placeholders would report as a file with nothing in it.
    private var readingPlaceholder: String {
        String(localized: "Reading the file…")
    }

    /// A file the plugin could not read is a failure, not an empty result. Showing the parser's
    /// message as grey placeholder text left the sheet with nothing to press but Cancel.
    private func unreadableFile(reason: String) -> some View {
        UnavailableStateView {
            Label(String(localized: "Cannot read this file"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason)
        } actions: {
            Button(String(localized: "Try Again")) {
                Task { await retryLoad() }
            }
        }
    }

    /// Per destination, so Try Again for one never reads the other again over its edits.
    @MainActor
    private func retryLoad() async {
        loadError = nil
        readAttempts[destination, default: 0] += 1
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var detectionSignatureObserver: some View {
        if let observer = ImportDetectionSignatureObservation.observer(
            for: currentPlugin,
            onChange: { detectionSignature = $0 }
        ) {
            observer
        }
    }

    private var mappingToolbar: some View {
        RowImportMappingToolbar(
            mapping: mapping,
            tableName: selectedTargetTable ?? "",
            fieldsFollowFileOrder: currentPlugin.map { type(of: $0).sourceFieldsFollowFileOrder } ?? false
        )
    }

    private var mappingTable: some View {
        VStack(spacing: 0) {
            mappingToolbar
                .padding(.horizontal)
                .padding(.vertical, 6)
            Divider()
            HStack(spacing: 12) {
                Toggle(String(localized: "Import all fields"), isOn: allMappingsIncluded)
                    .labelsHidden()
                    .help(String(localized: "Import all fields"))
                    .accessibilityLabel(Text("Import all fields"))
                    .frame(width: 16)
                Text("Field")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Column")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 240, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(mapping.rows) { row in
                        mappingRow(row)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }

    private func mappingRow(_ row: RowImportMapping.Row) -> some View {
        HStack(spacing: 12) {
            Toggle(row.field.name, isOn: mappingBinding(row).choice.include)
                .labelsHidden()
                .accessibilityLabel(Text(String(format: String(localized: "Import %@"), row.field.name)))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.field.name).lineLimit(1)
                if let sample = row.field.sampleValue, !sample.isEmpty {
                    Text(sample).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker(String(format: String(localized: "Column for %@"), row.field.name),
                   selection: mappingBinding(row).choice.column) {
                Text("Skip").tag(String?.none)
                ForEach(mapping.columns, id: \.self) { column in
                    Text(column).tag(String?.some(column))
                }
            }
            .labelsHidden()
            .frame(width: 240, alignment: .leading)
            .disabled(!row.choice.include)
        }
    }

    private var newColumnsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle(String(localized: "Create all columns"), isOn: allColumnsIncluded)
                    .labelsHidden()
                    .help(String(localized: "Create all columns"))
                    .accessibilityLabel(Text("Create all columns"))
                    .frame(width: 16)
                Text("Column")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading)
                Text("Type")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading)
                Text("Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30)
                Text("Null")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30)
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(newTable.columns) { row in
                        newColumnRow(row)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }

    private func newColumnRow(_ row: NewTableColumn) -> some View {
        let column = row.settings
        let settings = columnBinding(row).settings
        return HStack(spacing: 10) {
            Toggle(column.name, isOn: settings.include)
                .labelsHidden()
                .accessibilityLabel(Text(String(format: String(localized: "Create %@"), column.name)))
                .frame(width: 16)
            TextField("name", text: settings.name)
                .accessibilityLabel(String(localized: "Column name"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .disabled(!column.include)
            Picker(String(localized: "Type"), selection: typeBinding(row)) {
                ForEach(typeOptions(including: column.type), id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel(Text(String(format: String(localized: "Type of %@"), column.name)))
            .frame(width: 150)
            .disabled(!column.include)
            Toggle(String(localized: "Primary key"), isOn: settings.isPrimaryKey)
                .labelsHidden()
                .accessibilityLabel(Text(String(format: String(localized: "%@ is a primary key"), column.name)))
                .frame(minWidth: 30)
                .disabled(!column.include)
            Toggle(String(localized: "Nullable"), isOn: settings.isNullable)
                .labelsHidden()
                .accessibilityLabel(Text(String(format: String(localized: "%@ accepts null"), column.name)))
                .frame(minWidth: 30)
                .disabled(!column.include)
            TextField(String(localized: "Default, as SQL"), text: settings.defaultValue)
                .labelsHidden()
                .accessibilityLabel(Text(String(format: String(localized: "Default SQL for %@"), column.name)))
                .help(String(localized: "The SQL after DEFAULT. A text value needs its own quotes."))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .disabled(!column.include)
        }
    }

    // MARK: - Bindings

    private func mappingBinding(_ row: RowImportMapping.Row) -> Binding<RowImportMapping.Row> {
        guard let index = mapping.rows.firstIndex(where: { $0.id == row.id }) else {
            return .constant(row)
        }
        return $mapping.rows[index]
    }

    private func columnBinding(_ row: NewTableColumn) -> Binding<NewTableColumn> {
        guard let index = newTable.columns.firstIndex(where: { $0.id == row.id }) else {
            return .constant(row)
        }
        return $newTable.columns[index]
    }

    private var allMappingsIncluded: Binding<Bool> {
        Binding(
            get: { !mapping.rows.isEmpty && mapping.rows.allSatisfy(\.choice.include) },
            set: { mapping.setAllIncluded($0) }
        )
    }

    private var allColumnsIncluded: Binding<Bool> {
        Binding(
            get: { newTable.includesEveryColumn },
            set: { newTable.setAllIncluded($0) }
        )
    }

    private var validationMessage: String? {
        switch destination {
        case .existingTable:
            if mapping.mapsOneColumnTwice {
                return String(localized: "Each column can be mapped from only one field.")
            }
            return nil
        case .newTable:
            if let problem = newTableNameProblem {
                switch problem {
                case .blank:
                    return String(localized: "Enter a name for the new table.")
                case .nameTaken:
                    return String(
                        format: String(localized: "A table named %@ already exists."),
                        newTableName.trimmingCharacters(in: .whitespaces)
                    )
                case .reservedPrefix(let prefix):
                    return String(
                        format: String(localized: "This database keeps names beginning with %@ for itself."),
                        prefix
                    )
                case .tooLong(let maximumBytes):
                    return String(
                        format: String(localized: "This database allows at most %lld bytes in a table name."),
                        Int64(maximumBytes)
                    )
                }
            }
            switch newTable.problem {
            case .unnamedColumn:
                return String(localized: "Every included column needs a name.")
            case .duplicateName:
                return String(localized: "Column names must be unique.")
            case nil:
                return nil
            }
        }
    }

    private var dialectTypes: [String] {
        PluginManager.shared.columnTypesByCategory(for: connection.type)
            .values
            .flatMap { $0 }
            .sorted()
    }

    /// The selection has to be one of the options by exact spelling or the menu draws blank, and
    /// `typeOptions` suppresses its insert on a case-insensitive match. The getter resolves through
    /// the same comparison so a differently-cased stored type still selects its own row.
    private func typeBinding(_ row: NewTableColumn) -> Binding<String> {
        let type = row.settings.type
        let options = typeOptions(including: type)
        return Binding(
            get: { options.first { $0.caseInsensitiveCompare(type) == .orderedSame } ?? type },
            set: { columnBinding(row).settings.type.wrappedValue = $0 }
        )
    }

    private func typeOptions(including current: String) -> [String] {
        var types = dialectTypes
        if !types.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            types.insert(current, at: 0)
        }
        return types
    }

    // MARK: - Plugin

    private var currentPlugin: (any ImportFormatPlugin)? {
        pluginManager.importPlugin(forFormat: formatId)
    }

    private var canImport: Bool {
        guard !(importService?.state.isImporting ?? false), validationMessage == nil, currentReadIsReady else {
            return false
        }
        switch destination {
        case .existingTable:
            return selectedTargetTable != nil && mapping.hasMappedField
        case .newTable:
            return !newTableName.trimmingCharacters(in: .whitespaces).isEmpty && newTable.hasNamedColumn
        }
    }

    /// Import runs only what the rows show: a read of the file with the current options, into the current
    /// table and database, that finished without an error.
    private var currentReadIsReady: Bool {
        guard !isLoadingContext, loadError == nil else { return false }
        return currentReadHasLanded
    }

    /// The rows on screen answer the read for the current destination, table, database and options.
    private var currentReadHasLanded: Bool {
        switch destination {
        case .existingTable:
            return mapping.loadedRead == AnyHashable(sourceRead)
        case .newTable:
            return lastNewColumnsRead == sourceRead
        }
    }

    // MARK: - Loading

    /// Both failures used to leave an empty list and say nothing, so the destination picker offered
    /// "Select a table…" and nothing else with no way to tell an empty database from an unreachable
    /// one, and no way to ask again.
    ///
    /// Read through the sheet's own scope, the browse scope it took on opening, which is what the
    /// import writes to. The shared session driver is wherever a tab's execution last pinned it and
    /// nothing puts it back, so reading from it listed one database's tables and mapped their columns
    /// while the rows went to another's.
    @MainActor
    private func loadTables() async {
        guard !isLoadingTables else { return }
        isLoadingTables = true
        defer { isLoadingTables = false }
        if scope == nil {
            scope = DatabaseManager.shared.browseScope(for: connection.id)
        }
        guard let scope else {
            catalogNameKeys = nil
            tableListError = String(localized: "This connection is not open.")
            return
        }
        do {
            databaseObjects = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchTables()
            }
            catalogNameKeys = NewTableNaming.comparisonKeys(for: databaseObjects.map(\.name))
            tableListError = nil
            suggestNewTableName()
        } catch {
            catalogNameKeys = nil
            tableListError = error.localizedDescription
            Self.logger.warning("Failed to load tables: \(error.publicLogShape, privacy: .public)")
        }
    }

    /// Proposes a name straight away and again once the catalog arrives, because only the part that
    /// avoids a name already in use needs the catalog. Waiting for it would leave the field empty
    /// under a "name this table" warning while the list loaded, and empty for good if it failed.
    ///
    /// The second pass replaces this sheet's own earlier guess and nothing else: anything the user
    /// typed differs from `proposedTableName` and is left alone. A table this sheet already created
    /// is left out of the avoid-set for the same reason it is left out of the name check: a retry
    /// is meant to land back on it, and stepping the name to `_2` would strand the first one.
    @MainActor
    private func suggestNewTableName() {
        guard newTableName.isEmpty || newTableName == proposedTableName else { return }
        let ours = NewTableNaming.comparisonKeys(for: scope.map(newTablePlanner.createdTableNames(in:)) ?? [])
        let suggestion = NewTableNaming.suggestion(
            forFileNamed: sourceName,
            style: NewTableNameStyle.forDatabaseType(connection.type),
            avoiding: (catalogNameKeys ?? []).subtracting(ours)
        )
        proposedTableName = suggestion
        newTableName = suggestion
    }

    private var sourceRead: SourceRead {
        let isExisting = destination == .existingTable
        return SourceRead(
            destination: destination,
            scope: isExisting ? scope : nil,
            table: isExisting ? selectedTargetTable : nil,
            signature: detectionSignature,
            attempt: readAttempts[destination, default: 0]
        )
    }

    /// A read that succeeded is not repeated when switching back to its destination, and it clears an
    /// error the other destination left on screen.
    @MainActor
    private func read(_ request: SourceRead) async {
        switch request.destination {
        case .existingTable:
            guard let table = request.table else {
                isLoadingContext = false
                return
            }
            guard mapping.loadedRead != AnyHashable(request) else {
                showCachedRead()
                return
            }
            await loadExistingContext(table: table, for: request)
        case .newTable:
            guard lastNewColumnsRead != request else {
                showCachedRead()
                return
            }
            await loadNewColumns(for: request)
        }
    }

    private func showCachedRead() {
        isLoadingContext = false
        loadError = nil
    }

    @MainActor
    private func loadNewColumns(for request: SourceRead) async {
        guard let plugin = currentPlugin else {
            isLoadingContext = false
            return
        }
        isLoadingContext = true
        loadError = nil
        do {
            let fields = try await ImportFieldDetection.detectFields(plugin: plugin, at: fileURL, targetTable: nil)
            guard !Task.isCancelled else { return }
            let serverVersion = DatabaseManager.shared.driver(for: connection.id)?.serverVersion
            newTable.load(fields: fields) { inferredType in
                ImportTypeMapper.sqlType(for: inferredType, databaseType: connection.type, serverVersion: serverVersion)
            }
            lastNewColumnsRead = request
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            Self.logger.warning("Failed to read import fields: \(error.publicLogShape, privacy: .public)")
        }
        isLoadingContext = false
    }

    @MainActor
    private func loadExistingContext(table: String, for request: SourceRead) async {
        guard let plugin = currentPlugin, let scope = request.scope else {
            isLoadingContext = false
            return
        }
        isLoadingContext = true
        loadError = nil
        do {
            let columns = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchColumns(table: table)
            }.map(\.name)
            guard !Task.isCancelled else { return }
            let fields = try await ImportFieldDetection.detectFields(plugin: plugin, at: fileURL, targetTable: table)
            guard !Task.isCancelled else { return }
            mapping.load(fields: fields, columns: columns, for: TableScope(table: table, in: scope), read: request)
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            Self.logger.warning("Failed to read import fields: \(error.publicLogShape, privacy: .public)")
        }
        isLoadingContext = false
    }

    // MARK: - Import

    private func performImport() {
        guard let scope else {
            importError = DatabaseError.notConnected
            showErrorDialog = true
            return
        }
        guard currentReadIsReady else {
            if !isLoadingContext {
                readAttempts[destination, default: 0] += 1
            }
            return
        }
        switch destination {
        case .existingTable:
            guard let table = selectedTargetTable else { return }
            runImport(
                ImportPlan(
                    targetTable: table,
                    fields: mapping.fields,
                    columns: mapping.columns,
                    columnMapping: mapping.columnMapping,
                    newTable: nil
                ),
                scope: scope
            )
        case .newTable:
            let name = newTableName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let definition = newTable.definition(tableName: name) else {
                importError = Self.createTableStatementError
                showErrorDialog = true
                return
            }
            let columnMapping = newTable.columnMapping
            let fields = newTable.fields
            runImport(
                ImportPlan(
                    targetTable: name,
                    fields: fields,
                    columns: fields.compactMap { columnMapping[$0] },
                    columnMapping: columnMapping,
                    newTable: definition
                ),
                scope: scope
            )
        }
    }

    private static var createTableStatementError: NSError {
        NSError(
            domain: "RowImport", code: -1,
            userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not build the CREATE TABLE statement")]
        )
    }

    private func runImport(_ plan: ImportPlan, scope: DatabaseScope) {
        let service = ImportService(connection: connection)
        importService = service
        showProgressDialog = true
        let targetTable = plan.targetTable

        importTask = Task {
            do {
                if let newTable = plan.newTable {
                    try await prepareTable(newTable, scope: scope)
                }
                mapping.remember(
                    fields: plan.fields,
                    columns: plan.columns,
                    columnMapping: plan.columnMapping,
                    in: TableScope(table: targetTable, in: scope)
                )
                let result = try await service.importFile(
                    from: fileURL,
                    sourceName: sourceName,
                    formatId: formatId,
                    encoding: .utf8,
                    scope: scope,
                    targetTable: targetTable,
                    columnMapping: plan.columnMapping,
                    sourceFields: Set(plan.fields)
                )
                await MainActor.run {
                    showProgressDialog = false
                    importSucceeded = true
                    importResult = result
                    importedRows = DatabaseObjectChange(
                        connectionId: connection.id,
                        scope: scope,
                        name: targetTable,
                        kind: .rows
                    )
                    showSuccessDialog = true
                }
            } catch is PluginImportCancellationError {
                await MainActor.run {
                    showProgressDialog = false
                    TransferResultAlert.presentImportCancelled(
                        executedStatements: service.state.processedStatements,
                        window: hostWindow
                    ) {}
                }
            } catch {
                await MainActor.run {
                    showProgressDialog = false
                    importError = error
                    showErrorDialog = true
                }
            }
        }
    }

    @MainActor
    private func prepareTable(_ definition: PluginCreateTableDefinition, scope: DatabaseScope) async throws {
        guard ImportDataSinkAdapter.canWriteRows(into: connection.type) else {
            throw PluginImportError.importFailed(String(
                format: String(localized: "%@ cannot take rows from this file, so no table was created."),
                connection.type.rawValue
            ))
        }
        let tableName = definition.tableName
        let table = TableScope(table: tableName, in: scope)
        let statements = try await DatabaseManager.shared.createTableStatements(
            definition: definition,
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope)
        )
        guard !statements.isEmpty else { throw Self.createTableStatementError }
        let sql = statements.joined(separator: "\n")
        switch newTablePlanner.plan(forTable: table, createTableSQL: sql) {
        case .create:
            try await createTable(statements: statements, scope: scope)
            newTablePlanner.recordCreated(table, createTableSQL: sql)
        case .reuseAfterClearing:
            try await clearRows(of: tableName, scope: scope)
        case .nameTakenWithDifferentColumns:
            throw PluginImportError.importFailed(
                String(
                    format: String(localized: "The table %@ was already created with different columns. Choose another name."),
                    tableName
                )
            )
        }
    }

    @MainActor
    private func clearRows(of tableName: String, scope: DatabaseScope) async throws {
        let generator = try SQLStatementGenerator(
            tableName: tableName,
            columns: [],
            primaryKeyColumns: [],
            databaseType: connection.type
        )
        let sql = generator.deleteAllRowsStatement()
        try await authorize(
            sql: sql, kind: .destructiveQuery, description: String(localized: "Clear Table")
        )
        try await runOnLeasedDriver(sql, scope: scope)
    }

    /// One call per statement the driver wrote, because an engine that runs one statement per call refuses a table
    /// and its indexes sent together.
    private func createTable(statements: [String], scope: DatabaseScope) async throws {
        let script = SQLScriptText(databaseType: connection.type).script(statements)
        try await authorize(
            sql: script, kind: .schemaMutation, description: String(localized: "Create Table")
        )
        for statement in statements {
            try await runOnLeasedDriver(statement, scope: scope)
        }
        CatalogChangeService.post(
            .changed(CatalogChange(connectionId: connection.id, database: scope.database, kinds: .tables))
        )
    }

    /// The sheet's own statements take the same lease the import does, one at a time and always
    /// after `authorize` has returned. Taking it earlier would hold the connection's gate open
    /// across a safe-mode confirmation the user has not answered yet, and the gate is not
    /// reentrant, so the import that follows would then wait on a sheet waiting on the user.
    @MainActor
    private func runOnLeasedDriver(_ sql: String, scope: DatabaseScope) async throws {
        let route = DatabaseManager.shared.executionRoute(for: scope)
        _ = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: route,
            cancellation: .protectedWrite
        ) { driver in
            try await driver.execute(query: sql)
        }
    }

    /// Every statement this sheet issues on its own account goes through the gate. The retry path's
    /// `DELETE FROM` used to skip it while the `CREATE TABLE` beside it did not, so a connection
    /// set to confirm destructive statements emptied a table without asking.
    private func authorize(sql: String, kind: OperationKind, description: String) async throws {
        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: sql,
                kind: kind,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: description
            )
        )
        guard case .authorized = decision else {
            throw PluginImportError.importFailed(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }
    }
}
