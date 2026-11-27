//
//  ImportDialog.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit
import TableProSQLFile
import TableProSQLGrammar
import TableProUtilities

struct ImportDialog: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportDialog")
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialFileURL: URL?

    init(isPresented: Binding<Bool>, connection: DatabaseConnection, initialFileURL: URL?, initialFormatId: String) {
        self._isPresented = isPresented
        self.connection = connection
        self.initialFileURL = initialFileURL
        self._selectedFormatId = State(initialValue: initialFormatId)
        self._selectedEncoding = State(initialValue: TransferDialogStorage.shared.loadLastImportEncoding())
    }

    // MARK: - State

    @State private var fileURL: URL?
    @State private var filePreview: String = ""
    @State private var fileSize: Int64 = 0
    @State private var selectedEncoding: ImportEncoding
    @State private var detectedEncoding: ImportEncoding?
    @State private var selectedFormatId: String = "sql"
    @State private var settingsSnapshot: PluginSettingsSnapshot?
    @State private var importSucceeded = false
    @State private var phase: Phase = .form

    @State private var hostWindow: NSWindow?

    @State private var hasPreviewError = false
    @State private var loadFileTask: Task<Void, Never>?
    @State private var importTask: Task<Void, Never>?

    // MARK: - Import Service

    @State private var importService: ImportService?

    private enum Phase {
        case form
        case running
        case finished(TransferResult)
    }

    // MARK: - Body

    // A ZStack, not a Group, whose modifiers reach each phase view: a phase switch must not run onDisappear.
    var body: some View {
        ZStack {
            switch phase {
            case .form:
                formView
            case .running:
                if let service = importService {
                    ImportProgressView(service: service)
                }
            case .finished(let result):
                TransferResultView(
                    result,
                    onBack: result.returnsToForm ? { phase = .form } : nil,
                    onDone: { closeAfterRun() }
                ) {
                    if let report = result.errorReport {
                        Button("Save Report…") {
                            TransferResults.saveErrorReport(
                                report,
                                sourceFileName: fileURL?.lastPathComponent ?? "",
                                targetTable: nil,
                                window: hostWindow
                            )
                        }
                    }
                }
            }
        }
        .background {
            WindowAccessor { window in
                hostWindow = window
            }
        }
        .onAppear {
            let available = availableFormats
            if !available.contains(where: { type(of: $0).formatId == selectedFormatId }) {
                if let first = available.first {
                    selectedFormatId = type(of: first).formatId
                }
            }
            captureSettingsSnapshot()
        }
        // While running, the Stop button owns Escape and asks first.
        .onExitCommand {
            switch phase {
            case .form:
                isPresented = false
            case .running:
                break
            case .finished:
                closeAfterRun()
            }
        }
        .task {
            if let initialURL = initialFileURL, fileURL == nil {
                // Tracked like a picked file, so a pick made during a slow preview read cancels this load.
                let load = Task { await loadFile(initialURL) }
                loadFileTask = load
                await load.value
            }
        }
        .onChange(of: selectedEncoding) { _ in
            loadFileTask?.cancel()
            if let url = fileURL {
                loadFileTask = Task {
                    await loadFile(url)
                }
            }
        }
        .onDisappear {
            loadFileTask?.cancel()
            importTask?.cancel()
            if !importSucceeded {
                restoreSettingsSnapshot()
            }
        }
    }

    private var formView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                fileInfoView

                Divider()

                filePreviewView

                optionsView
            }
            .padding(16)

            Divider()

            footerView
        }
        .frame(width: 600)
    }

    // MARK: - Plugin Helpers

    private var availableFormats: [any ImportFormatPlugin] {
        let dbTypeId = connection.type.rawValue
        return pluginManager.allImportPlugins()
            .filter { plugin in
                let pluginType = type(of: plugin)
                return ImportRouting.isStatementFormat(
                    requiresTargetTable: pluginType.requiresTargetTable,
                    supportedDatabaseTypeIds: pluginType.supportedDatabaseTypeIds,
                    excludedDatabaseTypeIds: pluginType.excludedDatabaseTypeIds,
                    databaseTypeId: dbTypeId
                )
            }
            .sorted { type(of: $0).formatDisplayName < type(of: $1).formatDisplayName }
    }

    private var currentPlugin: (any ImportFormatPlugin)? {
        pluginManager.importPlugin(forFormat: selectedFormatId)
    }

    // MARK: - View Components

    private var fileInfoView: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: currentPlugin.map { type(of: $0).iconName } ?? "doc.text.fill")
                .font(.title)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(fileURL?.lastPathComponent ?? "")
                        .font(.body.weight(.semibold))

                    Spacer()

                    Button("Change File…") {
                        Task {
                            await selectFile()
                        }
                    }
                    .font(.callout)
                }

                Label(
                    ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file),
                    systemImage: "chart.bar.doc.horizontal"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filePreviewView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)

            SQLCodePreview(text: $filePreview)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Options")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button("Reset to Defaults") {
                    resetOptionsToDefaults()
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }

            // A plugin view of flat rows lines up with these rows; one wrapped in a VStack is a single row.
            Form {
                if availableFormats.count > 1 {
                    Picker("Format:", selection: $selectedFormatId) {
                        ForEach(availableFormats.map { (id: type(of: $0).formatId, name: type(of: $0).formatDisplayName) }, id: \.id) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Picker("Encoding:", selection: $selectedEncoding) {
                    ForEach(ImportEncoding.allCases) { enc in
                        Text(enc.label).tag(enc)
                    }
                }
                .pickerStyle(.menu)

                if let settable = currentPlugin as? any SettablePluginDiscoverable,
                   let pluginView = settable.settingsView() {
                    pluginView
                }
            }
            .formStyle(.columns)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerView: some View {
        DialogFooter {
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Button("Import") {
                performImport()
            }
            .buttonStyle(.borderedProminent)
            .disabled(fileURL == nil || (importService?.state.isImporting ?? false) || availableFormats.isEmpty || hasPreviewError)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func captureSettingsSnapshot() {
        settingsSnapshot = PluginSettingsSnapshot(
            plugins: availableFormats.compactMap { $0 as? any SettablePluginDiscoverable }
        )
    }

    private func restoreSettingsSnapshot() {
        settingsSnapshot?.restore()
        settingsSnapshot = nil
    }

    private func resetOptionsToDefaults() {
        selectedEncoding = .utf8
        guard let settable = currentPlugin as? any SettablePluginDiscoverable else { return }
        settable.resetSettingsToDefaults()
        settingsSnapshot?.recapture(settable)
    }

    private func recordSuccessfulImport() {
        importSucceeded = true
        if selectedEncoding != detectedEncoding {
            TransferDialogStorage.shared.saveLastImportEncoding(selectedEncoding)
        }
        settingsSnapshot = nil
    }

    private func closeAfterRun() {
        isPresented = false
        guard importSucceeded else { return }
        AppCommands.shared.refreshData.send(DataRefreshRequest(connectionId: connection.id))
    }

    @MainActor
    private func selectFile() async {
        guard let window = hostWindow else {
            Self.logger.warning("No host window captured, cannot present the file panel")
            return
        }

        let options = availableFormats.map {
            ImportFormatOption(
                id: type(of: $0).formatId,
                name: type(of: $0).formatDisplayName,
                acceptedFileExtensions: type(of: $0).acceptedFileExtensions
            )
        }
        guard !options.isEmpty else { return }

        let url = await ImportFilePanel.present(
            matching: options,
            message: String(localized: "Select a file to import"),
            in: window
        )
        guard let url, case .format(let formatId) = ImportFileFormatResolver.match(url, among: options) else { return }

        selectedFormatId = formatId
        loadFileTask?.cancel()
        self.loadFileTask = Task {
            await self.loadFile(url)
        }
    }

    @MainActor
    private func loadFile(_ url: URL) async {
        hasPreviewError = false

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            filePreview = String(localized: "Error: Selected path is not a regular file")
            hasPreviewError = true
            return
        }

        fileURL = url

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            fileSize = attrs[.size] as? Int64 ?? 0
        } catch {
            Self.logger.warning("Failed to get file attributes for \(url.path(percentEncoded: false), privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)")
            fileSize = 0
        }

        // A `.gz` is previewed from its first inflated bytes; the import inflates it as it reads, so no expanded copy is
        // written and no up-front pass lexes the whole file.
        do {
            let maxPreviewSize = 5 * 1_024 * 1_024
            let leading = try await Self.leadingBytes(of: url, limit: maxPreviewSize)
            // A newer pick owns the dialog now.
            guard !Task.isCancelled else { return }
            let previewData = leading.data

            if let preview = SQLDumpEncodingChoice.decodedPreview(
                previewData, as: selectedEncoding.encoding, isWholeFile: leading.isWholeFile
            ) {
                filePreview = preview
                hasPreviewError = false
            } else if let detected = SQLDumpEncodingChoice.encoding(
                replacing: selectedEncoding.encoding,
                forPreview: previewData,
                isWholeFile: leading.isWholeFile,
                family: TransactionEngineFamily.of(connection.type).dumpFamily,
                grammar: sessionGrammar
            ).flatMap({ found in ImportEncoding.allCases.first { $0.encoding == found } }) {
                Self.logger.info("Preview did not decode as \(selectedEncoding.rawValue, privacy: .public); switching to the detected \(detected.rawValue, privacy: .public)")
                detectedEncoding = detected
                selectedEncoding = detected
                return
            } else {
                filePreview = String(format: String(localized: "Failed to load preview using encoding: %@. Try selecting a different text encoding."), selectedEncoding.label)
                hasPreviewError = true
            }
        } catch {
            filePreview = String(format: String(localized: "Failed to load preview: %@"), error.localizedDescription)
            hasPreviewError = true
        }
    }

    // Off the main actor: inflating the first 5 MB of a `.gz` takes a moment.
    @concurrent
    nonisolated private static func leadingBytes(of url: URL, limit: Int) async throws -> (data: Data, isWholeFile: Bool) {
        try SQLFileByteReader.leadingBytes(of: url, limit: limit)
    }

    @MainActor
    private var sessionGrammar: SQLLexicalGrammar {
        SQLLexicalResolver.executionGrammar(for: connection.type, connectionId: connection.id)
    }

    private func performImport() {
        guard let url = fileURL else { return }

        let service = ImportService(connection: connection)
        importService = service

        phase = .running

        importTask = Task {
            do {
                guard let scope = DatabaseManager.shared.browseScope(for: connection.id) else {
                    throw DatabaseError.notConnected
                }
                let result = try await service.importFile(
                    from: url,
                    formatId: selectedFormatId,
                    encoding: selectedEncoding.encoding,
                    scope: scope
                )

                await MainActor.run {
                    recordSuccessfulImport()
                    phase = .finished(TransferResults.importSucceeded(result: result, runResult: service.stopResult))
                }
            } catch is PluginImportCancellationError {
                await MainActor.run {
                    phase = .finished(TransferResults.importStopped(service.stopResult))
                }
            } catch let refusal as ExecutionGateError {
                await MainActor.run {
                    guard case .denied = refusal else {
                        phase = .form
                        return
                    }
                    phase = .finished(TransferResults.importFailed(error: refusal, result: service.stopResult))
                }
                return
            } catch {
                await MainActor.run {
                    phase = .finished(TransferResults.importFailed(error: error, result: service.stopResult))
                }
            }
            CatalogChangeService.post(.changed(CatalogChange(connectionId: connection.id, kinds: .everything)))
        }
    }
}
