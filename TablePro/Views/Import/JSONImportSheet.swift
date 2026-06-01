//
//  JSONImportSheet.swift
//  TablePro
//
//  Dedicated import sheet for row-based formats (JSON / NDJSON):
//  pick a destination table and map each source field to a column.
//

import os
import SwiftUI
import TableProPluginKit

struct JSONImportSheet: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "JSONImportSheet")

    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let fileURL: URL

    private struct FieldMapping: Identifiable {
        let field: PluginImportField
        var include: Bool
        var targetColumn: String?
        var id: String { field.name }
    }

    @State private var availableTables: [TableInfo] = []
    @State private var selectedTargetTable: String?
    @State private var targetColumns: [String] = []
    @State private var mappings: [FieldMapping] = []
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
                    destinationSection
                    if selectedTargetTable != nil {
                        Divider()
                        mappingSection
                    }
                    if let settable = currentPlugin as? any SettablePluginDiscoverable,
                       let optionsView = settable.settingsView() {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Options")
                                .font(.callout.weight(.semibold))
                            optionsView
                        }
                    }
                }
                .padding(16)
            }
            .frame(width: 640, height: 560)

            Divider()
            footerView
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await loadTables() }
        .onChange(of: selectedTargetTable) { _, newValue in
            mappings = []
            targetColumns = []
            guard let table = newValue else { return }
            Task { await loadTargetContext(table: table) }
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
        selectedTargetTable != nil
            && mappings.contains { $0.include && $0.targetColumn != nil }
            && !(importService?.state.isImporting ?? false)
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
        }
    }

    private var destinationSection: some View {
        HStack(spacing: 8) {
            Text("Import into:")
                .font(.body)
                .frame(width: 90, alignment: .leading)
            Picker("", selection: $selectedTargetTable) {
                Text("Select a table…").tag(String?.none)
                ForEach(availableTables, id: \.id) { table in
                    Text(table.name).tag(String?.some(table.name))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            if isLoadingContext {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }

    private var mappingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Field Mapping")
                    .font(.callout.weight(.semibold))
                Spacer()
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.red)
                }
            }
            HStack(spacing: 8) {
                Text("Import").frame(width: 50, alignment: .leading)
                Text("JSON field").frame(width: 170, alignment: .leading)
                Text("Column").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach($mappings) { $mapping in
                mappingRow($mapping)
            }
        }
    }

    private func mappingRow(_ mapping: Binding<FieldMapping>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: mapping.include)
                .labelsHidden()
                .frame(width: 50, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(mapping.wrappedValue.field.name)
                    .font(.body)
                    .lineLimit(1)
                if let sample = mapping.wrappedValue.field.sampleValue, !sample.isEmpty {
                    Text(sample)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 170, alignment: .leading)

            Picker("", selection: mapping.targetColumn) {
                Text("Skip").tag(String?.none)
                ForEach(targetColumns, id: \.self) { column in
                    Text(column).tag(String?.some(column))
                }
            }
            .labelsHidden()
            .disabled(!mapping.wrappedValue.include)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    private func loadTargetContext(table: String) async {
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
        guard let targetTable = selectedTargetTable else { return }

        var mapping: [String: String] = [:]
        for entry in mappings where entry.include {
            if let column = entry.targetColumn {
                mapping[entry.field.name] = column
            }
        }

        let service = ImportService(connection: connection)
        importService = service
        showProgressDialog = true

        importTask = Task {
            do {
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
}
