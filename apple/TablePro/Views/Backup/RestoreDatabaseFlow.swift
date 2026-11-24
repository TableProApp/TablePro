//
//  RestoreDatabaseFlow.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProSQLGrammar

struct RestoreDatabaseFlow: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialDatabase: String
    let sourceURL: URL

    @StateObject private var service = NativeDumpService(kind: .restore)
    @State private var phase: Phase = .resolvingTarget
    @State private var hostWindow: NSWindow?
    @State private var progress: TransferProgress?

    private enum Phase: Equatable {
        case resolvingTarget
        case pickDatabase
        case running(database: String)
        case finished(database: String, skippedSettings: [String])
        case failed(message: String, targetMayBeModified: Bool)
        case cancelled
    }

    var body: some View {
        Group {
            switch phase {
            case .resolvingTarget:
                resolvingView
            case .pickDatabase:
                pickerView
            case .running(let database):
                TransferProgressSheet(
                    progress: service.state.restoreProgress(database: database, last: progress)
                ) {
                    service.cancel()
                }
            case .finished(let database, let skippedSettings):
                BackupResultSheet(
                    kind: .restore,
                    outcome: .restoreSuccess(
                        database: database, source: sourceURL, skippedSettings: skippedSettings),
                    onClose: { isPresented = false },
                    onShowInFinder: nil
                )
            case .failed(let message, let targetMayBeModified):
                BackupResultSheet(
                    kind: .restore,
                    outcome: .failure(
                        message: message, targetMayBeModified: targetMayBeModified),
                    onClose: { isPresented = false },
                    onShowInFinder: nil
                )
            case .cancelled:
                BackupResultSheet(
                    kind: .restore,
                    outcome: .cancelled,
                    onClose: { isPresented = false },
                    onShowInFinder: nil
                )
            }
        }
        .background {
            WindowAccessor { window in hostWindow = window }
        }
        .onChange(of: serviceState) { newState in
            handleServiceStateChange(newState)
        }
        .task { await resolveTarget() }
    }

    private var resolvingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Preparing\u{2026}")
                .foregroundStyle(.secondary)
        }
        .frame(width: 480, height: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // SQLite and DuckDB report no database list, which would leave the picker with no way forward.
    @MainActor
    private func resolveTarget() async {
        guard phase == .resolvingTarget else { return }
        let databases = await BackupScopeLoader.databases(for: connection)
        guard databases.count > 1 else {
            await startRestore(database: databases.first?.name ?? initialDatabase)
            return
        }
        phase = .pickDatabase
    }

    private var pickerView: some View {
        VStack(spacing: 0) {
            sourceBanner
            Divider()
            RestoreTargetPicker(
                connection: connection,
                currentDatabase: initialDatabase,
                onCancel: { isPresented = false },
                onSelect: { database in
                    Task { await startRestore(database: database) }
                }
            )
        }
    }

    private var sourceBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.zipper")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore from")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sourceURL.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 480, alignment: .leading)
    }

    private var serviceState: NativeDumpState { service.state }

    // DuckDB writes either one `.duckdb` file or a folder of Parquet; only the file system says which.
    private var formatId: String? {
        let formats = NativeDumpRegistry.formats(for: connection.type)
        guard formats.count > 1 else { return formats.first?.id }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
        return formats.first { $0.producesDirectory == isDirectory.boolValue }?.id ?? formats[0].id
    }

    private func handleServiceStateChange(_ state: NativeDumpState) {
        switch state {
        case .running(let database, _, _, _):
            phase = .running(database: database)
            progress = state.restoreProgress(database: database, last: progress)
        case .finished(let database, _, _, let skippedSettings):
            phase = .finished(database: database, skippedSettings: skippedSettings)
            CatalogChangeService.post(
                .changed(CatalogChange(connectionId: connection.id, database: database, kinds: .everything))
            )
        case .failed(let message, let targetMayBeModified):
            phase = .failed(message: message, targetMayBeModified: targetMayBeModified)
            if targetMayBeModified {
                CatalogChangeService.post(.changed(CatalogChange(connectionId: connection.id, kinds: .everything)))
            }
        case .cancelled:
            phase = .cancelled
            CatalogChangeService.post(.changed(CatalogChange(connectionId: connection.id, kinds: .everything)))
        case .idle, .cancelling:
            break
        }
    }

    // The dump tools overwrite without asking, so the confirmation is the last step before a write.
    private func startRestore(database: String) async {
        guard let message = RestoreConfirmationText.message(for: connection.type, formatId: formatId) else {
            phase = .failed(
                message: NativeDumpError.unsupportedDatabase.localizedDescription, targetMayBeModified: false)
            return
        }
        guard await AlertHelper.confirmDestructive(
            title: String(
                format: String(localized: "Restore into \u{201C}%@\u{201D}?"), database),
            message: message,
            confirmButton: String(localized: "Restore"),
            window: hostWindow
        ) else {
            isPresented = false
            return
        }
        guard await NativeDumpPasswordExposure.confirm(
            connection: connection,
            formatId: formatId,
            window: hostWindow
        ) else { return }
        phase = .running(database: database)
        do {
            try await service.start(
                connection: connection,
                database: database,
                fileURL: sourceURL,
                formatId: formatId
            )
        } catch {
            phase = .failed(message: error.localizedDescription, targetMayBeModified: false)
        }
    }
}

private struct RestoreTargetPicker: View {
    let currentDatabase: String
    let databaseType: DatabaseType
    let connectionId: UUID
    let onCancel: () -> Void
    let onSelect: (String) -> Void
    @StateObject private var viewModel: DatabaseSwitcherViewModel

    init(
        connection: DatabaseConnection,
        currentDatabase: String,
        onCancel: @escaping () -> Void,
        onSelect: @escaping (String) -> Void
    ) {
        self.currentDatabase = currentDatabase
        self.databaseType = connection.type
        self.connectionId = connection.id
        self.onCancel = onCancel
        self.onSelect = onSelect
        self._viewModel = StateObject(
            wrappedValue: DatabaseSwitcherViewModel(
                connectionId: connection.id,
                currentDatabase: currentDatabase,
                databaseType: connection.type,
                switchTarget: .database,
                sidebarState: SharedSidebarState.forConnection(connection.id)
            ))
    }

    var body: some View {
        NavigationStack {
            DatabaseSwitcherList(
                viewModel: viewModel,
                currentDatabase: currentDatabase,
                activeDatabase: currentDatabase,
                databaseType: databaseType,
                connectionId: connectionId,
                commands: nil,
                onCommit: onSelect,
                dismiss: onCancel
            )
            .navigationTitle(String(localized: "Restore Database"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Restore")) {
                        if let database = viewModel.primarySelection {
                            onSelect(database)
                        }
                    }
                    .disabled(viewModel.primarySelection == nil)
                }
            }
        }
        .frame(width: 480, height: 460)
    }
}
