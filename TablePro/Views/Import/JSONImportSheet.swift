//
//  JSONImportSheet.swift
//  TablePro
//
//  Dedicated import sheet for row-based formats (JSON / NDJSON):
//  map each source field to a column in an existing table, or create a new
//  table with columns inferred from the data.
//

import os
import SwiftUI
import TableProPluginKit

struct JSONImportSheet: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "JSONImportSheet")

    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let fileURL: URL

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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileInfoSection
                    Divider()
                    destinationPicker
                    destinationDetail
                    Divider()
                    centralSection
                    optionsSection
                }
                .padding(16)
            }
            .frame(width: 700, height: 560)

            Divider()
            footerView
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: - Plugin

    private var currentPlugin: (any ImportFormatPlugin)? {
        let ext = fileURL.pathExtension.lowercased()
        return PluginManager.shared.allImportPlugins().first {
            type(of: $0).requiresTargetTable && type(of: $0).acceptedFileExtensions.contains(ext)
        }
    }

    private var formatId: String {
        currentPlugin.map { type(of: $0).formatId } ?? "json"
    }

    private var canImport: Bool {
        guard !(importService?.state.isImporting ?? false) else { return false }
        switch destination {
        case .existingTable:
            return selectedTargetTable != nil && mappings.contains { $0.include && $0.targetColumn != nil }
        case .newTable:
            return !newTableName.trimmingCharacters(in: .whitespaces).isEmpty
                && newColumns.contains { $0.include && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    // MARK: - Sections

    private var fileInfoSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "curlybraces")
                .font(.title)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(fileURL.lastPathComponent)
                    .font(.body.weight(.semibold))
                Text("Import JSON rows into a table")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoadingContext {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var destinationPicker: some View {
        Picker("Destination", selection: $destination) {
            Text("Existing table").tag(Destination.existingTable)
            Text("New table").tag(Destination.newTable)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 300)
    }

    @ViewBuilder
    private var destinationDetail: some View {
        switch destination {
        case .existingTable:
            HStack(spacing: 8) {
                Text("Import into:")
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: $selectedTargetTable) {
                    Text("Select a table…").tag(String?.none)
                    ForEach(availableTables, id: \.id) { table in
                        Text(table.name).tag(String?.some(table.name))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                Spacer()
            }
        case .newTable:
            HStack(spacing: 8) {
                Text("New table:")
                    .frame(width: 90, alignment: .leading)
                TextField("table_name", text: $newTableName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var centralSection: some View {
        switch destination {
        case .existingTable:
            if selectedTargetTable != nil {
                mappingSection
            } else {
                Text("Select a destination table to map fields.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .newTable:
            newColumnsSection
        }
    }

    // MARK: - Existing-table mapping

    private var mappingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            mappingHeader
            ForEach($mappings) { $mapping in
                HStack(spacing: 8) {
                    Toggle("", isOn: $mapping.include)
                        .labelsHidden()
                        .frame(width: 50, alignment: .leading)
                    fieldLabel(mapping.field)
                        .frame(width: 200, alignment: .leading)
                    Picker("", selection: $mapping.targetColumn) {
                        Text("Skip").tag(String?.none)
                        ForEach(targetColumns, id: \.self) { column in
                            Text(column).tag(String?.some(column))
                        }
                    }
                    .labelsHidden()
                    .disabled(!mapping.include)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var mappingHeader: some View {
        HStack {
            Text("Field Mapping").font(.callout.weight(.semibold))
            Spacer()
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - New-table columns

    private var newColumnsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Columns").font(.callout.weight(.semibold))
                Spacer()
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
            }
            HStack(spacing: 8) {
                Text("Create").frame(width: 50, alignment: .leading)
                Text("Column").frame(width: 150, alignment: .leading)
                Text("Type").frame(width: 130, alignment: .leading)
                Text("PK").frame(width: 34, alignment: .leading)
                Text("Null").frame(width: 40, alignment: .leading)
                Text("Default").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach($newColumns) { $column in
                HStack(spacing: 8) {
                    Toggle("", isOn: $column.include).labelsHidden().frame(width: 50, alignment: .leading)
                    TextField("name", text: $column.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .disabled(!column.include)
                    TextField("type", text: $column.type)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .disabled(!column.include)
                    Toggle("", isOn: $column.isPrimaryKey).labelsHidden().frame(width: 34, alignment: .leading)
                        .disabled(!column.include)
                    Toggle("", isOn: $column.isNullable).labelsHidden().frame(width: 40, alignment: .leading)
                        .disabled(!column.include)
                    TextField("", text: $column.defaultValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .disabled(!column.include)
                }
            }
        }
    }

    private func fieldLabel(_ field: PluginImportField) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(field.name).font(.body).lineLimit(1)
            if let sample = field.sampleValue, !sample.isEmpty {
                Text(sample).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        if let settable = currentPlugin as? any SettablePluginDiscoverable,
           let optionsView = settable.settingsView() {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Options").font(.callout.weight(.semibold))
                optionsView
            }
        }
    }

    private var footerView: some View {
        HStack {
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Import") { performImport() }
                .buttonStyle(.borderedProminent)
                .disabled(!canImport)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
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
                    type: JSONImportTypeMapper.sqlType(for: field.inferredType, databaseType: connection.type),
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
                    domain: "JSONImport", code: -1,
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
