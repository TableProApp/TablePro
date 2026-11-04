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
import TableProSQLGrammar

struct RowImportSheet: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    private static let logger = Logger(subsystem: "com.TablePro", category: "RowImportSheet")

    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let fileURL: URL
    let sourceName: String
    let formatId: String

    let edit: RowImportSheetEdit?

    private typealias Destination = RowImportDestination

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
        let rowWriting: ImportRowWriting
    }

    @State private var destination: Destination = .existingTable
    @State private var writeMode: ImportWriteMode = .insert
    @State private var chosenMatchKey: ImportMatchKey?

    @State private var scope: DatabaseScope?

    @State private var databaseObjects: [TableInfo] = []

    @State private var catalogNameKeys: Set<String>?
    @State private var tableListError: String?

    @State private var isLoadingTables = false
    @State private var selectedTargetTable: String?
    @StateObject private var mapping = RowImportMapping()
    @State private var newTableName: String = ""

    @State private var proposedTableName: String = ""
    @State private var newTable = NewTableDraft()
    @State private var isLoadingContext = false

    @State private var detectionSignature = ""
    @State private var readAttempts: [Destination: Int] = [:]
    @State private var lastNewColumnsRead: SourceRead?
    @State private var loadError: String?

    @FocusState private var newTableNameFocused: Bool

    @State private var settingsSnapshot: PluginSettingsSnapshot?
    @State private var importSucceeded = false

    @State private var importService: ImportService?
    @State private var importResult: PluginImportResult?
    @State private var importTally: ImportRowTally?
    @State private var importedRows: DatabaseObjectChange?
    @State private var importError: (any Error)?
    @State private var showProgressDialog = false
    @State private var showSuccessDialog = false
    @State private var showErrorDialog = false
    @State private var importTask: Task<Void, Never>?

    @State private var newTablePlanner = NewTableImportPlanner()

    @State private var hostWindow: NSWindow?

    init(
        isPresented: Binding<Bool>,
        connection: DatabaseConnection,
        fileURL: URL,
        sourceName: String,
        formatId: String,
        edit: RowImportSheetEdit? = nil
    ) {
        _isPresented = isPresented
        self.connection = connection
        self.fileURL = fileURL
        self.sourceName = sourceName
        self.formatId = formatId
        self.edit = edit
        guard let edit else {
            _scope = State(initialValue: DatabaseManager.shared.browseScope(for: connection.id))
            return
        }
        let target = edit.target
        _scope = State(initialValue: edit.scope)
        _destination = State(initialValue: target.destination)
        _selectedTargetTable = State(initialValue: target.existingTable)
        _newTableName = State(initialValue: target.newTableName)
        _proposedTableName = State(initialValue: target.proposedTableName)
        _newTable = State(initialValue: target.newTable)
        _newTablePlanner = State(initialValue: edit.planner)
        _mapping = StateObject(wrappedValue: RowImportMapping(seed: target.mapping.map { mapping in
            (TableScope(table: mapping.table, in: edit.scope), mapping.choicesByField)
        }))
    }

    // MARK: - Derived catalog state

    private var availableTables: [TableInfo] {
        databaseObjects.filter(\.type.acceptsImportedRows)
    }

    private var newTableNameProblem: NewTableNameProblem? {
        let trimmed = newTableName.trimmingCharacters(in: .whitespaces)
        if let edit, !trimmed.isEmpty, edit.takenTableNames.contains(trimmed.lowercased()) {
            return .nameTaken
        }
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

            if edit == nil {
                optionsForm
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                Divider()
            }

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
            if edit == nil {
                settingsSnapshot = PluginSettingsSnapshot(
                    plugins: [currentPlugin as? any SettablePluginDiscoverable].compactMap { $0 })
            }
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
                ImportProgressView(service: service)
            }
        }
        .onChange(of: showSuccessDialog) { isShowing in
            guard isShowing else { return }
            TransferResultAlert.presentImportSuccess(
                result: importResult,
                rowTally: importTally,
                runResult: importService?.stopResult,
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
            TransferResultAlert.presentImportFailure(error: importError, result: importService?.stopResult, window: hostWindow) {
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

                // A run of several files inserts only, so one file of it has no mode to choose.
                if edit == nil {
                    GridRow {
                        Text("Import as:")
                        Picker(String(localized: "Import as"), selection: $writeMode) {
                            ForEach(ImportWriteMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help(String(localized: """
                            Update changes the rows whose key is in the file. Insert or Update also adds the rest, \
                            and Insert, Skip Existing adds only rows whose key is not in the table. Columns not \
                            mapped keep their values.
                            """))
                    }
                }

                if writeMode.matchesExistingRows {
                    GridRow {
                        Text("Match on:")
                        Picker(String(localized: "Match on"), selection: matchKeyBinding) {
                            ForEach(mapping.matchKeys) { key in
                                Text(key.label).tag(ImportMatchKey?.some(key))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280, alignment: .leading)
                        .disabled(mapping.matchKeys.isEmpty)
                    }
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
                NoticeLabel(message, severity: .error)
                    .font(.caption)
                    .lineLimit(2)
            }
        } actions: {
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(edit == nil ? String(localized: "Import") : String(localized: "Done")) { performImport() }
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

    private var readingPlaceholder: String {
        String(localized: "Reading the file…")
    }

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

    private var matchKey: ImportMatchKey? {
        chosenMatchKey.flatMap { chosen in mapping.matchKeys.first { $0 == chosen } } ?? mapping.matchKeys.first
    }

    private var matchKeyBinding: Binding<ImportMatchKey?> {
        Binding(
            get: { matchKey },
            set: { chosenMatchKey = $0 }
        )
    }

    private var rowWriting: ImportRowWriting {
        guard writeMode.matchesExistingRows, let matchKey else { return .insert }
        return ImportRowWriting(mode: writeMode, keyColumns: matchKey.columns)
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
            guard selectedTargetTable != nil, currentReadHasLanded else { return nil }
            return ImportRowWritingProblem.of(
                mode: writeMode,
                key: matchKey,
                mappedColumns: Array(mapping.columnMapping.values)
            )?.message
        case .newTable:
            if let problem = newTableNameProblem {
                return problem.message(for: newTableName)
            }
            return newTable.problem?.message
        }
    }

    private var dialectTypes: [String] {
        PluginManager.shared.columnTypesByCategory(for: connection.type)
            .values
            .flatMap { $0 }
            .sorted()
    }

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

    private var currentReadIsReady: Bool {
        guard !isLoadingContext, loadError == nil else { return false }
        return currentReadHasLanded
    }

    private var currentReadHasLanded: Bool {
        switch destination {
        case .existingTable:
            return mapping.loadedRead == AnyHashable(sourceRead)
        case .newTable:
            return lastNewColumnsRead == sourceRead
        }
    }

    // MARK: - Loading

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

    @MainActor
    private func suggestNewTableName() {
        guard newTableName.isEmpty || newTableName == proposedTableName else { return }
        let ours = NewTableNaming.comparisonKeys(for: scope.map(newTablePlanner.createdTableNames(in:)) ?? [])
        let suggestion = NewTableNaming.suggestion(
            forFileNamed: sourceName,
            style: NewTableNameStyle.forDatabaseType(connection.type),
            avoiding: (catalogNameKeys ?? []).subtracting(ours).union(edit?.takenTableNames ?? [])
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
            let (columns, indexes) = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                (try await driver.fetchColumns(table: table), try? await driver.fetchIndexes(table: table))
            }
            guard !Task.isCancelled else { return }
            if indexes == nil {
                Self.logger.warning("Could not read the target's indexes, so only its primary key can be matched on")
            }
            let fields = try await ImportFieldDetection.detectFields(plugin: plugin, at: fileURL, targetTable: table)
            guard !Task.isCancelled else { return }
            mapping.load(
                fields: fields,
                columns: columns.map(\.name),
                matchKeys: ImportMatchKey.options(columns: columns, indexes: indexes ?? []),
                for: TableScope(table: table, in: scope),
                read: request
            )
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            Self.logger.warning("Failed to read import fields: \(error.publicLogShape, privacy: .public)")
        }
        isLoadingContext = false
    }

    // MARK: - Import

    private func performImport() {
        if let edit {
            finishEdit(edit)
            return
        }
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
                    newTable: nil,
                    rowWriting: rowWriting
                ),
                scope: scope
            )
        case .newTable:
            let name = newTableName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let definition = newTable.definition(tableName: name) else {
                importError = RowImportTableMaker.statementError
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
                    newTable: definition,
                    rowWriting: .insert
                ),
                scope: scope
            )
        }
    }

    private func finishEdit(_ edit: RowImportSheetEdit) {
        guard currentReadIsReady else { return }
        var target = RowImportTarget(
            destination: destination,
            existingTable: selectedTargetTable,
            newTableName: newTableName,
            proposedTableName: proposedTableName,
            mapping: nil,
            newTable: newTable
        )
        if destination == .existingTable, let table = selectedTargetTable {
            target.mapping = RowImportTarget.Mapping(
                table: table,
                fields: mapping.rows.map(\.field),
                columns: mapping.columns,
                choices: mapping.choices
            )
        }
        edit.onDone(target)
        isPresented = false
    }

    private func runImport(_ plan: ImportPlan, scope: DatabaseScope) {
        let service = ImportService(connection: connection)
        importService = service
        showProgressDialog = true
        let targetTable = plan.targetTable

        importTask = Task {
            do {
                var authorization: OperationReceipt?
                if let newTable = plan.newTable {
                    authorization = try await RowImportTableMaker(connection: connection).prepare(
                        [newTable],
                        scope: scope,
                        planner: newTablePlanner,
                        importRun: service.run
                    ) { table, sql in
                        newTablePlanner.recordCreated(table, createTableSQL: sql)
                    }
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
                    sourceFields: Set(plan.fields),
                    rowWriting: plan.rowWriting,
                    authorization: authorization
                )
                await MainActor.run {
                    showProgressDialog = false
                    importSucceeded = true
                    importResult = result
                    importTally = service.state.rowTally
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
                        result: service.stopResult,
                        window: hostWindow
                    ) {}
                }
            } catch ExecutionGateError.cancelledByUser {
                await MainActor.run { showProgressDialog = false }
            } catch {
                await MainActor.run {
                    showProgressDialog = false
                    importError = error
                    showErrorDialog = true
                }
            }
        }
    }
}
