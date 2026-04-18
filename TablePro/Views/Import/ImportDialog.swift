//
//  ImportDialog.swift
//  TablePro
//
//  Plugin-aware import dialog.
//

import AppKit
import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

struct ImportDialog: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportDialog")
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialFileURL: URL?

    // MARK: - State

    @State private var fileURL: URL?
    @State private var filePreview: String = ""
    @State private var fileSize: Int64 = 0
    @State private var statementCount: Int = 0
    @State private var isCountingStatements = false
    @State private var selectedEncoding: ImportEncoding = .utf8
    @State private var selectedFormatId: String = "sql"
    @State private var showProgressDialog = false
    @State private var showSuccessDialog = false
    @State private var showErrorDialog = false
    @State private var importResult: PluginImportResult?
    @State private var importError: (any Error)?

    @State private var hasPreviewError = false
    @State private var tempPreviewURL: URL?
    @State private var loadFileTask: Task<Void, Never>?

    // MARK: - Import Service

    @State private var importService: ImportService?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                fileInfoView

                Divider()

                if availableFormats.count > 1 {
                    formatPickerView
                    Divider()
                }

                filePreviewView

                optionsView
            }
            .padding(16)
            .frame(width: 600, height: 550)

            Divider()

            footerView
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let available = availableFormats
            if !available.contains(where: { type(of: $0).formatId == selectedFormatId }) {
                if let first = available.first {
                    selectedFormatId = type(of: first).formatId
                }
            }
        }
        .onExitCommand {
            if !(importService?.state.isImporting ?? false) {
                isPresented = false
            }
        }
        .task {
            if let initialURL = initialFileURL, fileURL == nil {
                await loadFile(initialURL)
            }
        }
        .onDisappear {
            loadFileTask?.cancel()
            cleanupTempFiles()
        }
        .sheet(isPresented: $showProgressDialog) {
            ImportProgressView(
                processedStatements: importService?.state.processedStatements ?? 0,
                estimatedTotalStatements: importService?.state.estimatedTotalStatements ?? 0,
                statusMessage: importService?.state.statusMessage ?? ""
            ) {
                importService?.cancelImport()
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSuccessDialog) {
            ImportSuccessView(
                result: importResult
            ) {
                showSuccessDialog = false
                isPresented = false
                NotificationCenter.default.post(name: .refreshData, object: nil)
            }
        }
        .sheet(isPresented: $showErrorDialog) {
            ImportErrorView(
                error: importError
            ) {
                showErrorDialog = false
            }
        }
    }

    // MARK: - Plugin Helpers

    private var availableFormats: [any ImportFormatPlugin] {
        let dbTypeId = connection.type.rawValue
        return PluginManager.shared.importPlugins.values
            .filter { plugin in
                let supported = type(of: plugin).supportedDatabaseTypeIds
                let excluded = type(of: plugin).excludedDatabaseTypeIds
                if !supported.isEmpty && !supported.contains(dbTypeId) {
                    return false
                }
                if excluded.contains(dbTypeId) {
                    return false
                }
                return true
            }
            .sorted { type(of: $0).formatDisplayName < type(of: $1).formatDisplayName }
    }

    private var currentPlugin: (any ImportFormatPlugin)? {
        PluginManager.shared.importPlugins[selectedFormatId]
    }

    // MARK: - View Components

    private var fileInfoView: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: currentPlugin.map { type(of: $0).iconName } ?? "doc.text.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(fileURL?.lastPathComponent ?? "")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    Button("Change File...") {
                        Task {
                            await selectFile()
                        }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                }

                HStack(spacing: 16) {
                    Label(
                        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file),
                        systemImage: "chart.bar.doc.horizontal"
                    )
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                    .foregroundStyle(.secondary)

                    if isCountingStatements {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Counting...")
                                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                                .foregroundStyle(.secondary)
                        }
                    } else if statementCount > 0 {
                        Label("\(statementCount) statements", systemImage: "list.bullet")
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formatPickerView: some View {
        HStack(spacing: 8) {
            Text("Format:")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                .frame(width: 80, alignment: .leading)

            Picker("", selection: $selectedFormatId) {
                ForEach(availableFormats.map { (id: type(of: $0).formatId, name: type(of: $0).formatDisplayName) }, id: \.id) { item in
                    Text(item.name).tag(item.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            Spacer()
        }
    }

    private var filePreviewView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, weight: .semibold))
                .foregroundStyle(.primary)

            SQLCodePreview(text: $filePreview)
                .frame(height: availableFormats.count > 1 ? 220 : 280)
                .clipShape(RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: ThemeEngine.shared.activeTheme.cornerRadius.medium)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Options")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 12) {
                // Encoding picker (always shown, independent of plugin)
                HStack(spacing: 8) {
                    Text("Encoding:")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                        .frame(width: 80, alignment: .leading)

                    Picker("", selection: $selectedEncoding) {
                        ForEach(ImportEncoding.allCases) { enc in
                            Text(enc.rawValue).tag(enc)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .onChange(of: selectedEncoding) { _, _ in
                        loadFileTask?.cancel()
                        if let url = fileURL {
                            loadFileTask = Task {
                                await loadFile(url)
                            }
                        }
                    }

                    Spacer()
                }

                // Plugin-provided options
                if let settable = currentPlugin as? any SettablePluginDiscoverable,
                   let pluginView = settable.settingsView() {
                    pluginView
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerView: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }

            Spacer()

            Button("Import") {
                performImport()
            }
            .buttonStyle(.borderedProminent)
            .disabled(fileURL == nil || (importService?.state.isImporting ?? false) || availableFormats.isEmpty || hasPreviewError)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(16)
    }

    // MARK: - Actions

    @MainActor
    private func selectFile() async {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }

        let panel = NSOpenPanel()

        let extensions = currentPlugin.map { type(of: $0).acceptedFileExtensions } ?? ["sql", "gz"]
        let allowedTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = allowedTypes.isEmpty ? [.data] : allowedTypes
        panel.allowsMultipleSelection = false
        panel.message = "Select file to import"

        let response = await panel.presentAsSheet(for: window)
        guard response == .OK, let url = panel.url else { return }

        self.loadFileTask = Task {
            await self.loadFile(url)
        }
    }

    @MainActor
    private func loadFile(_ url: URL) async {
        cleanupTempFiles()
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
            Self.logger.warning("Failed to get file attributes for \(url.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
            fileSize = 0
        }

        let urlToRead: URL
        do {
            urlToRead = try await decompressIfNeeded(url)
            if urlToRead != url {
                tempPreviewURL = urlToRead
            }
        } catch {
            filePreview = String(format: String(localized: "Failed to decompress file: %@"), error.localizedDescription)
            hasPreviewError = true
            return
        }

        do {
            let handle = try FileHandle(forReadingFrom: urlToRead)
            defer {
                do {
                    try handle.close()
                } catch {
                    Self.logger.warning("Failed to close file handle for preview: \(error.localizedDescription, privacy: .public)")
                }
            }

            let maxPreviewSize = 5 * 1_024 * 1_024
            let previewData = handle.readData(ofLength: maxPreviewSize)

            if let preview = String(data: previewData, encoding: selectedEncoding.encoding) {
                filePreview = preview
                hasPreviewError = false
            } else {
                filePreview = String(format: String(localized: "Failed to load preview using encoding: %@. Try selecting a different text encoding."), selectedEncoding.rawValue)
                hasPreviewError = true
            }
        } catch {
            filePreview = String(format: String(localized: "Failed to load preview: %@"), error.localizedDescription)
            hasPreviewError = true
        }

        Task {
            await countStatements(url: urlToRead)
        }
    }

    @MainActor
    private func countStatements(url: URL) async {
        isCountingStatements = true
        statementCount = 0

        do {
            let encoding = selectedEncoding.encoding
            let parser = SQLFileParser()
            let count = try await Task.detached {
                try await parser.countStatements(url: url, encoding: encoding)
            }.value
            statementCount = count
        } catch {
            Self.logger.warning("Failed to count statements: \(error.localizedDescription, privacy: .public)")
            statementCount = 0
        }

        isCountingStatements = false
    }

    private func performImport() {
        guard let url = fileURL else { return }

        let service = ImportService(connection: connection)
        importService = service

        showProgressDialog = true

        Task {
            do {
                let result = try await service.importFile(
                    from: url,
                    formatId: selectedFormatId,
                    encoding: selectedEncoding.encoding
                )

                await MainActor.run {
                    showProgressDialog = false
                    importResult = result
                    showSuccessDialog = true
                }
            } catch is PluginImportCancellationError {
                await MainActor.run {
                    showProgressDialog = false
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

    private func cleanupTempFiles() {
        if let tempURL = tempPreviewURL {
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                Self.logger.error(
                    "cleanupTempFiles: Failed to remove tempPreviewURL at \(tempURL.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            tempPreviewURL = nil
        }
    }

    private func fileSystemPath(for url: URL) -> String {
        url.path()
    }

    private func decompressIfNeeded(_ url: URL) async throws -> URL {
        try await FileDecompressor.decompressIfNeeded(url, fileSystemPath: fileSystemPath)
    }
}

