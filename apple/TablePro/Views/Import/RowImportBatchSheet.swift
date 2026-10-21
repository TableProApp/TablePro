//
//  RowImportBatchSheet.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

/// Several files, or a folder of them, imported as rows into a table each in one run. Every file starts on the table
/// its name matches or a new table named after it, Edit… opens the one-file sheet on it, and the options of each
/// format are set once for every file in that format.
struct RowImportBatchSheet: View {
    private struct EditRequest: Identifiable {
        let id: RowImportBatch.File.ID
    }

    @ObservedObject private var pluginManager = PluginManager.shared
    @Binding var isPresented: Bool
    let connection: DatabaseConnection

    @StateObject private var batch: RowImportBatch
    @State private var shownFormat: String?
    @State private var editing: EditRequest?
    @State private var isDropTargeted = false

    /// The plugins' options are shared and persistent, and this sheet edits them in place, so Cancel puts them back.
    @State private var settingsSnapshot: PluginSettingsSnapshot?
    @State private var importSucceeded = false
    @State private var importService: ImportService?
    @State private var showProgressDialog = false
    @State private var importTask: Task<Void, Never>?

    /// The sheet's own window for its alerts, never `NSApp.keyWindow`, which is the progress sheet while it closes.
    @State private var hostWindow: NSWindow?

    init(
        isPresented: Binding<Bool>,
        connection: DatabaseConnection,
        files: [ImportBatchFiles.File],
        leftOut: [URL]
    ) {
        _isPresented = isPresented
        self.connection = connection
        _batch = StateObject(wrappedValue: RowImportBatch(
            files: files,
            leftOut: leftOut,
            connection: connection,
            scope: DatabaseManager.shared.browseScope(for: connection.id),
            services: .live(for: connection)
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding()
            Divider()

            fileTable
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                .sheet(item: $editing) { request in
                    editSheet(for: request.id)
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    accept(providers)
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
            if !batch.leftOut.isEmpty || batch.tableListError != nil {
                notes
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            Divider()

            optionsForm
                .padding(.horizontal)
                .padding(.vertical, 10)
            Divider()

            footerView
                .padding()
        }
        .frame(minWidth: 780, minHeight: 600, idealHeight: 680, maxHeight: .infinity)
        .background {
            WindowAccessor { window in
                hostWindow = window
            }
        }
        .background { signatureObservers }
        .task {
            settingsSnapshot = PluginSettingsSnapshot(plugins: batch.formatIds.compactMap {
                plugin(for: $0) as? any SettablePluginDiscoverable
            })
            for formatId in batch.formatIds {
                batch.setSignature(plugin(for: formatId)?.fieldDetectionSignature ?? "", for: formatId)
            }
            await batch.loadTables()
        }
        .task(id: batch.readRequest) {
            await batch.readFiles()
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
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "tablecells")
                .font(.title)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(ImportService.batchName(fileCount: batch.files.count))
                    .font(.headline)
                Text("Import the rows of each file into its own table")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if batch.isLoadingTables || batch.isReading {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Files

    private var fileTable: some View {
        Table(batch.files) {
            TableColumn("") { file in
                Toggle(file.sourceName, isOn: includedBinding(file.id))
                    .labelsHidden()
                    .accessibilityLabel(Text(String(format: String(localized: "Import %@"), file.sourceName)))
            }
            .width(20)
            TableColumn("File") { file in
                Text(file.sourceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path(percentEncoded: false))
                    .foregroundStyle(file.isIncluded ? .primary : .secondary)
            }
            .width(min: 120, ideal: 190)
            TableColumn("Format") { file in
                Text(batch.formatName(file.formatId))
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Destination") { file in
                destinationPicker(file)
                    .disabled(!file.isIncluded)
            }
            .width(min: 170, ideal: 230)
            TableColumn("Columns") { file in
                columnsCell(file)
                    .disabled(!file.isIncluded)
            }
            .width(min: 170, ideal: 230)
        }
    }

    private func destinationPicker(_ file: RowImportBatch.File) -> some View {
        Picker(
            String(format: String(localized: "Destination for %@"), file.sourceName),
            selection: choiceBinding(file.id)
        ) {
            Text(newTableLabel(file)).tag(RowImportBatch.Choice.newTable)
            Divider()
            ForEach(tableChoices(for: file), id: \.self) { table in
                Text(table).tag(RowImportBatch.Choice.existingTable(table))
            }
        }
        .labelsHidden()
    }

    private func newTableLabel(_ file: RowImportBatch.File) -> String {
        let name = file.target.newTableName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return String(localized: "New table") }
        return String(format: String(localized: "New table %@"), name)
    }

    /// The table a file already points at stays listed when the table list could not be read, or the menu would
    /// draw blank.
    private func tableChoices(for file: RowImportBatch.File) -> [String] {
        var names = batch.availableTables.map(\.name)
        if let current = file.target.existingTable, !names.contains(current) {
            names.insert(current, at: 0)
        }
        return names
    }

    private func columnsCell(_ file: RowImportBatch.File) -> some View {
        HStack(spacing: 6) {
            if let problem = batch.problem(of: file), file.isIncluded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(problem)
                    .accessibilityLabel(Text(problem))
            }
            Text(batch.summary(of: file))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if case .failed = file.read {
                Button(String(localized: "Try Again")) { batch.retryRead(of: file.id) }
                    .buttonStyle(.link)
            } else {
                Button(String(localized: "Edit…")) { editing = EditRequest(id: file.id) }
                    .buttonStyle(.link)
                    .disabled(batch.scope == nil)
                    .accessibilityLabel(Text(String(format: String(localized: "Edit the import of %@"), file.sourceName)))
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !batch.leftOut.isEmpty {
                Label(
                    String(
                        format: String(localized: "Left out, because they do not import into a table: %@"),
                        batch.leftOut.map(\.lastPathComponent).formatted(.list(type: .and))
                    ),
                    systemImage: "info.circle"
                )
                .lineLimit(2)
            }
            if let error = batch.tableListError {
                HStack(spacing: 6) {
                    Label(
                        String(format: String(localized: "Could not read the table list. %@"), error),
                        systemImage: "exclamationmark.triangle"
                    )
                    .lineLimit(2)
                    Button(String(localized: "Try Again")) {
                        Task { await batch.loadTables() }
                    }
                    .buttonStyle(.link)
                    .disabled(batch.isLoadingTables)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A dropped file or folder joins the run, read the same way as a folder chosen in the panel.
    private func accept(_ providers: [NSItemProvider]) -> Bool {
        let lookup = ImportFormatLookup.live
        let options = lookup.offeredFormats(connection.type)
        let rowFormats = Set(options.map(\.id).filter { lookup.requiresTargetTable($0) == true })
        guard !rowFormats.isEmpty else { return false }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    adopt(ImportBatchFiles.resolve([url], among: options) { rowFormats.contains($0) })
                }
            }
        }
        return true
    }

    private func adopt(_ resolution: ImportBatchFiles.Resolution) {
        let newFormats = Set(resolution.files.map(\.formatId)).subtracting(batch.formatIds)
        batch.add(resolution)
        for formatId in newFormats {
            if let settable = plugin(for: formatId) as? any SettablePluginDiscoverable {
                settingsSnapshot?.include(settable)
            }
            batch.setSignature(plugin(for: formatId)?.fieldDetectionSignature ?? "", for: formatId)
        }
    }

    @ViewBuilder
    private func editSheet(for id: RowImportBatch.File.ID) -> some View {
        if let file = batch.file(id), let edit = batch.edit(for: id, onDone: { batch.apply($0, to: id) }) {
            RowImportSheet(
                isPresented: Binding(
                    get: { editing?.id == id },
                    set: { if !$0 { editing = nil } }
                ),
                connection: connection,
                fileURL: file.url,
                sourceName: file.sourceName,
                formatId: file.formatId,
                edit: edit
            )
        }
    }

    // MARK: - Options

    private var currentFormat: String? {
        let formats = batch.formatIds
        if let shownFormat, formats.contains(shownFormat) { return shownFormat }
        return formats.first
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Options").font(.callout.weight(.semibold))
                if batch.formatIds.count > 1 {
                    Picker(String(localized: "Options for"), selection: formatBinding) {
                        ForEach(batch.formatIds, id: \.self) { formatId in
                            Text(batch.formatName(formatId)).tag(formatId)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let formatId = currentFormat,
               let settable = plugin(for: formatId) as? any SettablePluginDiscoverable,
               let optionsView = settable.settingsView() {
                optionsView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var signatureObservers: some View {
        ForEach(batch.formatIds, id: \.self) { formatId in
            if let observer = RowImportOptionsObservation.observer(
                for: plugin(for: formatId),
                onChange: { signature, configuration in
                    batch.setSignature(signature, for: formatId)
                    batch.setConfiguration(configuration, for: formatId)
                }
            ) {
                observer
            }
        }
    }

    private func plugin(for formatId: String) -> (any ImportFormatPlugin)? {
        pluginManager.importPlugin(forFormat: formatId)
    }

    // MARK: - Footer

    private var footerView: some View {
        DialogFooter {
            if let message = batch.problem, !batch.isReading || batch.includedFiles.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if batch.isReading {
                Text("Reading the files…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Import") { performImport() }
                .buttonStyle(.borderedProminent)
                .disabled(!batch.canImport || importService?.state.isImporting == true)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Bindings

    private func includedBinding(_ id: RowImportBatch.File.ID) -> Binding<Bool> {
        Binding(
            get: { batch.file(id)?.isIncluded ?? false },
            set: { batch.setIncluded($0, for: id) }
        )
    }

    private func choiceBinding(_ id: RowImportBatch.File.ID) -> Binding<RowImportBatch.Choice> {
        Binding(
            get: { batch.file(id).map(batch.choice(for:)) ?? .newTable },
            set: { batch.choose($0, for: id) }
        )
    }

    private var formatBinding: Binding<String> {
        Binding(
            get: { currentFormat ?? "" },
            set: { shownFormat = $0 }
        )
    }

    // MARK: - Import

    private func performImport() {
        guard let scope = batch.scope else {
            TransferResultAlert.presentImportFailure(error: DatabaseError.notConnected, window: hostWindow) {}
            return
        }
        guard let plan = batch.plan(), let policy = batch.policy else { return }
        let service = ImportService(connection: connection)
        importService = service
        showProgressDialog = true

        importTask = Task {
            do {
                var authorization: OperationReceipt?
                if !plan.newTables.isEmpty {
                    authorization = try await RowImportTableMaker(connection: connection).prepare(
                        plan.newTables,
                        scope: scope,
                        planner: batch.planner,
                        description: String(
                            format: String(localized: "Import %@"),
                            ImportService.batchName(fileCount: plan.items.count)
                        )
                    ) { table, sql in
                        batch.planner.recordCreated(table, createTableSQL: sql)
                    }
                }
                for mapping in plan.mappings {
                    RowImportMapping.remember(
                        fields: mapping.fields,
                        columns: mapping.columns,
                        columnMapping: mapping.columnMapping,
                        in: TableScope(table: mapping.table, in: scope)
                    )
                }
                let report = try await service.importFiles(
                    plan.items,
                    scope: scope,
                    policy: policy,
                    authorization: authorization
                )
                showProgressDialog = false
                present(report, scope: scope)
            } catch ExecutionGateError.cancelledByUser {
                showProgressDialog = false
            } catch is CancellationError {
                showProgressDialog = false
            } catch {
                showProgressDialog = false
                TransferResultAlert.presentImportFailure(error: error, window: hostWindow) {}
            }
        }
    }

    /// A run that finished closes the sheet. One that stopped stays open, so a changed setting can run it again.
    private func present(_ report: RowImportBatchReport, scope: DatabaseScope) {
        let completed = report.ending == .completed
        if completed {
            importSucceeded = true
        }
        TransferResultAlert.presentBatchImportResult(report, window: hostWindow) {
            if report.rowsKept {
                for table in Set(report.files.map(\.targetTable)) {
                    AppCommands.shared.objectChanged.send(
                        DatabaseObjectChange(connectionId: connection.id, scope: scope, name: table, kind: .rows)
                    )
                }
            }
            if completed {
                isPresented = false
            }
        }
    }
}

/// The options a format's own view edits, followed for every format of a run: the signature decides the reads, and
/// the error handling and transaction options decide whether the files can run together.
private struct RowImportOptionsObserver<Plugin: ImportFormatPlugin & ObservableObject>: View {
    @ObservedObject var plugin: Plugin
    let onChange: (String, RowImportRunner.Configuration?) -> Void

    private var key: String {
        let configuration = plugin.rowImportConfiguration
        return [
            plugin.fieldDetectionSignature,
            configuration?.errorHandling.rawValue ?? "",
            configuration.map { String($0.wrapInTransaction) } ?? "",
            configuration.map { String($0.deleteExistingRows) } ?? "",
        ].joined(separator: "|")
    }

    var body: some View {
        Color.clear
            .onAppear { report() }
            .onChange(of: key) { _ in report() }
    }

    private func report() {
        onChange(plugin.fieldDetectionSignature, plugin.rowImportConfiguration)
    }
}

private enum RowImportOptionsObservation {
    @MainActor
    static func observer(
        for plugin: (any ImportFormatPlugin)?,
        onChange: @escaping (String, RowImportRunner.Configuration?) -> Void
    ) -> AnyView? {
        guard let observable = plugin as? any ImportFormatPlugin & ObservableObject else { return nil }
        return makeObserver(for: observable, onChange: onChange)
    }

    @MainActor
    private static func makeObserver<Plugin: ImportFormatPlugin & ObservableObject>(
        for plugin: Plugin,
        onChange: @escaping (String, RowImportRunner.Configuration?) -> Void
    ) -> AnyView {
        AnyView(RowImportOptionsObserver(plugin: plugin, onChange: onChange))
    }
}
