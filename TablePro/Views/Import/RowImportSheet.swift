//
//  RowImportSheet.swift
//  TablePro
//
//  Import sheet for row-based formats (JSON, NDJSON, CSV): map each source
//  field to a column in an existing table, or create a new table with columns
//  inferred from the data. The format plugin supplies the icon, name, and the
//  field-detection options shown in this sheet.
//

import Combine
import os
import SwiftUI
import TableProPluginKit

struct RowImportSheet: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RowImportSheet")

    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let fileURL: URL
    let formatId: String

    private enum Destination: Hashable {
        case existingTable
        case newTable
    }

    private struct FieldMapping: Identifiable {
        let field: PluginImportField
        var include: Bool
        var targetColumn: String?
        var id: String { field.name }
    }

    private struct NewColumn: Identifiable {
        let field: PluginImportField
        var include: Bool
        var name: String
        var type: String
        var isPrimaryKey: Bool
        var isNullable: Bool
        var defaultValue: String
        var id: String { field.name }
    }

    @State private var destination: Destination = .existingTable
    @State private var availableTables: [TableInfo] = []
    @State private var selectedTargetTable: String?
    @State private var targetColumns: [String] = []
    @State private var mappings: [FieldMapping] = []
    @State private var newTableName: String = ""
    @State private var newColumns: [NewColumn] = []
    @State private var newColumnsLoaded = false
    @State private var isLoadingContext = false
    @State private var loadError: String?

    @State private var importService: ImportService?
    @State private var importResult: PluginImportResult?
    @State private var importError: (any Error)?
    @State private var showProgressDialog = false
    @State private var showSuccessDialog = false
    @State private var showErrorDialog = false
    @State private var importTask: Task<Void, Never>?

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
        .frame(width: 720, height: 640)
        .task {
            await loadTables()
            await loadNewColumns()
        }
        .onChange(of: selectedTargetTable) { _, newValue in
            mappings = []
            targetColumns = []
            guard destination == .existingTable, let table = newValue else { return }
            Task { await loadExistingContext(table: table) }
        }
        .onChange(of: currentPlugin?.fieldDetectionSignature) { _, _ in
            Task { await redetectFields() }
        }
        .onDisappear { importTask?.cancel() }
        .sheet(isPresented: $showProgressDialog) {
            if let service = importService {
                ImportProgressView(service: service) { service.cancelImport() }
                    .interactiveDismissDisabled()
            }
        }
        .sheet(isPresented: $showSuccessDialog, onDismiss: {
            isPresented = false
            AppCommands.shared.refreshData.send(connection.id)
        }) {
            ImportSuccessView(result: importResult) { showSuccessDialog = false }
        }
        .sheet(isPresented: $showErrorDialog) {
            ImportErrorView(error: importError) { showErrorDialog = false }
        }
    }

    // MARK: - Header / forms

    private var headerView: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: currentPlugin.map { type(of: $0).iconName } ?? "tablecells")
                .font(.title)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileURL.lastPathComponent)
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
                Picker("", selection: $destination) {
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
                    Picker("", selection: $selectedTargetTable) {
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
                }
            }
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
        HStack {
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            if let message = validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Import") { performImport() }
                .buttonStyle(.borderedProminent)
                .disabled(!canImport)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Content tables

    @ViewBuilder
    private var contentArea: some View {
        switch destination {
        case .existingTable:
            if selectedTargetTable == nil {
                placeholder("Choose a destination table to map fields.")
            } else if mappings.isEmpty {
                placeholder(loadError ?? "No fields found in the file.")
            } else {
                mappingTable
            }
        case .newTable:
            if newColumns.isEmpty {
                placeholder(loadError ?? "No columns found in the file.")
            } else {
                newColumnsTable
            }
        }
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

    private var mappingTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: allMappingsIncluded)
                    .labelsHidden()
                    .help(String(localized: "Import all fields"))
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
                    ForEach(mappings) { row in
                        mappingRow(row)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }

    private func mappingRow(_ row: FieldMapping) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: mappingBinding(row).include)
                .labelsHidden()
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.field.name).lineLimit(1)
                if let sample = row.field.sampleValue, !sample.isEmpty {
                    Text(sample).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: mappingBinding(row).targetColumn) {
                Text("Skip").tag(String?.none)
                ForEach(targetColumns, id: \.self) { column in
                    Text(column).tag(String?.some(column))
                }
            }
            .labelsHidden()
            .frame(width: 240, alignment: .leading)
            .disabled(!row.include)
        }
    }

    private var newColumnsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: allColumnsIncluded)
                    .labelsHidden()
                    .help(String(localized: "Create all columns"))
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
                    .frame(width: 30)
                Text("Null")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
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
                    ForEach(newColumns) { row in
                        newColumnRow(row)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }

    private func newColumnRow(_ row: NewColumn) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: columnBinding(row).include)
                .labelsHidden()
                .frame(width: 16)
            TextField("name", text: columnBinding(row).name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .disabled(!row.include)
            Menu {
                ForEach(typeOptions(including: row.type), id: \.self) { type in
                    Button {
                        columnBinding(row).type.wrappedValue = type
                    } label: {
                        if type.caseInsensitiveCompare(row.type) == .orderedSame {
                            Label(type, systemImage: "checkmark")
                        } else {
                            Text(type)
                        }
                    }
                }
            } label: {
                Text(row.type)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 150)
            .disabled(!row.include)
            Toggle("", isOn: columnBinding(row).isPrimaryKey)
                .labelsHidden()
                .frame(width: 30)
                .disabled(!row.include)
            Toggle("", isOn: columnBinding(row).isNullable)
                .labelsHidden()
                .frame(width: 30)
                .disabled(!row.include)
            TextField("", text: columnBinding(row).defaultValue)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .disabled(!row.include)
        }
    }

    // MARK: - Bindings

    private func mappingBinding(_ row: FieldMapping) -> Binding<FieldMapping> {
        guard let index = mappings.firstIndex(where: { $0.id == row.id }) else {
            return .constant(row)
        }
        return $mappings[index]
    }

    private func columnBinding(_ row: NewColumn) -> Binding<NewColumn> {
        guard let index = newColumns.firstIndex(where: { $0.id == row.id }) else {
            return .constant(row)
        }
        return $newColumns[index]
    }

    private var allMappingsIncluded: Binding<Bool> {
        Binding(
            get: { !mappings.isEmpty && mappings.allSatisfy(\.include) },
            set: { value in for index in mappings.indices { mappings[index].include = value } }
        )
    }

    private var allColumnsIncluded: Binding<Bool> {
        Binding(
            get: { !newColumns.isEmpty && newColumns.allSatisfy(\.include) },
            set: { value in for index in newColumns.indices { newColumns[index].include = value } }
        )
    }

    private var validationMessage: String? {
        switch destination {
        case .existingTable:
            let columns = mappings.filter { $0.include }.compactMap { $0.targetColumn?.lowercased() }
            if Set(columns).count != columns.count {
                return String(localized: "Each column can be mapped from only one field.")
            }
            return nil
        case .newTable:
            let names = newColumns
                .filter { $0.include }
                .map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
            if names.contains(where: \.isEmpty) {
                return String(localized: "Every included column needs a name.")
            }
            if Set(names).count != names.count {
                return String(localized: "Column names must be unique.")
            }
            return nil
        }
    }

    private var dialectTypes: [String] {
        PluginManager.shared.columnTypesByCategory(for: connection.type)
            .values
            .flatMap { $0 }
            .sorted()
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
        PluginManager.shared.importPlugin(forFormat: formatId)
    }

    private var canImport: Bool {
        guard !(importService?.state.isImporting ?? false), validationMessage == nil else { return false }
        switch destination {
        case .existingTable:
            return selectedTargetTable != nil && mappings.contains { $0.include && $0.targetColumn != nil }
        case .newTable:
            return !newTableName.trimmingCharacters(in: .whitespaces).isEmpty
                && newColumns.contains { $0.include && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    // MARK: - Loading

    @MainActor
    private func loadTables() async {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return }
        do {
            availableTables = try await driver.fetchTables().filter { $0.type == .table }
        } catch {
            Self.logger.warning("Failed to load tables: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private func loadNewColumns() async {
        guard !newColumnsLoaded, let plugin = currentPlugin else { return }
        isLoadingContext = true
        defer { isLoadingContext = false }
        do {
            let fields = try plugin.detectSourceFields(at: fileURL, targetTable: nil)
            newColumns = fields.map { field in
                NewColumn(
                    field: field,
                    include: true,
                    name: field.name,
                    type: ImportTypeMapper.sqlType(for: field.inferredType, databaseType: connection.type),
                    isPrimaryKey: false,
                    isNullable: true,
                    defaultValue: ""
                )
            }
            newColumnsLoaded = true
        } catch {
            loadError = error.localizedDescription
            Self.logger.warning("Failed to read import fields: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private func loadExistingContext(table: String) async {
        guard let driver = DatabaseManager.shared.driver(for: connection.id),
              let plugin = currentPlugin else { return }
        isLoadingContext = true
        loadError = nil
        defer { isLoadingContext = false }
        do {
            let columns = try await driver.fetchColumns(table: table).map(\.name)
            let fields = try plugin.detectSourceFields(at: fileURL, targetTable: table)
            targetColumns = columns
            mappings = fields.map { field in
                let match = columns.first { $0.caseInsensitiveCompare(field.name) == .orderedSame }
                return FieldMapping(field: field, include: match != nil, targetColumn: match)
            }
        } catch {
            loadError = error.localizedDescription
            Self.logger.warning("Failed to read import fields: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private func redetectFields() async {
        switch destination {
        case .existingTable:
            guard let table = selectedTargetTable else { return }
            await loadExistingContext(table: table)
        case .newTable:
            newColumnsLoaded = false
            await loadNewColumns()
        }
    }

    // MARK: - Import

    private func performImport() {
        switch destination {
        case .existingTable:
            guard let table = selectedTargetTable else { return }
            runImport(targetTable: table, mapping: existingMapping(), createTableSQL: nil)
        case .newTable:
            let name = newTableName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let sql = buildCreateTableSQL(tableName: name) else {
                importError = NSError(
                    domain: "RowImport", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not build the CREATE TABLE statement")]
                )
                showErrorDialog = true
                return
            }
            runImport(targetTable: name, mapping: newTableMapping(), createTableSQL: sql)
        }
    }

    private func existingMapping() -> [String: String] {
        var mapping: [String: String] = [:]
        for entry in mappings where entry.include {
            if let column = entry.targetColumn {
                mapping[entry.field.name] = column
            }
        }
        return mapping
    }

    private func newTableMapping() -> [String: String] {
        var mapping: [String: String] = [:]
        for column in newColumns where column.include && !column.name.trimmingCharacters(in: .whitespaces).isEmpty {
            mapping[column.field.name] = column.name
        }
        return mapping
    }

    private func buildCreateTableSQL(tableName: String) -> String? {
        let included = newColumns.filter {
            $0.include
                && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.type.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !included.isEmpty else { return nil }

        let definition = PluginCreateTableDefinition(
            tableName: tableName,
            columns: included.map { column in
                PluginColumnDefinition(
                    name: column.name,
                    dataType: column.type,
                    isNullable: column.isNullable,
                    defaultValue: column.defaultValue.isEmpty ? nil : column.defaultValue,
                    isPrimaryKey: column.isPrimaryKey,
                    autoIncrement: false,
                    comment: nil,
                    unsigned: false,
                    onUpdate: nil,
                    charset: nil,
                    collation: nil
                )
            },
            primaryKeyColumns: included.filter(\.isPrimaryKey).map(\.name)
        )

        let pluginDriver = (DatabaseManager.shared.driver(for: connection.id) as? PluginDriverAdapter)?.schemaPluginDriver
        return pluginDriver?.generateCreateTableSQL(definition: definition)
    }

    private func runImport(targetTable: String, mapping: [String: String], createTableSQL: String?) {
        let service = ImportService(connection: connection)
        importService = service
        showProgressDialog = true

        importTask = Task {
            do {
                if let createTableSQL {
                    try await createTable(sql: createTableSQL)
                }
                let result = try await service.importFile(
                    from: fileURL,
                    formatId: formatId,
                    encoding: .utf8,
                    targetTable: targetTable,
                    columnMapping: mapping
                )
                await MainActor.run {
                    showProgressDialog = false
                    importResult = result
                    showSuccessDialog = true
                }
            } catch is PluginImportCancellationError {
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

    private func createTable(sql: String) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw DatabaseError.notConnected
        }
        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: connection.id,
                databaseType: connection.type,
                sql: sql,
                kind: .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: String(localized: "Create Table")
            )
        )
        guard case .authorized = decision else {
            throw PluginImportError.importFailed(decision.deniedReason ?? String(localized: "Operation not permitted"))
        }
        _ = try await driver.execute(query: sql)
    }
}
