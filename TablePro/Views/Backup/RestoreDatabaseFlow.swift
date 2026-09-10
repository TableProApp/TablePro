//
//  RestoreDatabaseFlow.swift
//  TablePro
//

import AppKit
import SwiftUI

struct RestoreDatabaseFlow: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialDatabase: String
    let sourceURL: URL

    @State private var service = NativeDumpService(kind: .restore)
    @State private var phase: Phase = .resolvingTarget
    @State private var hostWindow: NSWindow?

    private enum Phase: Equatable {
        case resolvingTarget
        case pickDatabase
        case running(database: String)
        case finished(database: String)
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
                BackupProgressSheet(
                    kind: .restore,
                    database: database,
                    bytesWritten: 0,
                    totalBytes: nil,
                    isCancelling: service.state == .cancelling,
                    onCancel: { service.cancel() }
                )
            case .finished(let database):
                BackupResultSheet(
                    kind: .restore,
                    outcome: .restoreSuccess(database: database, source: sourceURL),
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
        .onChange(of: serviceState) { _, newState in
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

    /// An engine that reaches one database is not asked which one.
    ///
    /// SQLite reports an empty database list, so the picker rendered its empty state with a
    /// permanently dimmed Restore button and no way forward but Cancel. DuckDB is the same shape.
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
            DatabaseSwitcherSheet(
                isPresented: $isPresented,
                mode: .restore,
                currentDatabase: initialDatabase,
                databaseType: connection.type,
                connectionId: connection.id,
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

    /// Which of an engine's formats this file is. DuckDB writes either one `.duckdb` file or a
    /// folder of Parquet, and only the file system says which one the user picked.
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
        case .finished(let database, _, _):
            phase = .finished(database: database)
        case .failed(let message, let targetMayBeModified):
            phase = .failed(message: message, targetMayBeModified: targetMayBeModified)
        case .cancelled:
            phase = .cancelled
        case .idle, .cancelling:
            break
        }
    }

    /// A restore replays a dump into a database that already has contents, and the tools it drives
    /// do not ask. Picking a database in the list used to be the last step before the first write.
    private func startRestore(database: String) async {
        guard await AlertHelper.confirmDestructive(
            title: String(
                format: String(localized: "Restore into \u{201C}%@\u{201D}?"), database),
            message: String(
                localized: """
                    The dump is replayed into this database. Objects it names are overwritten and \
                    the change cannot be undone.
                    """),
            confirmButton: String(localized: "Restore"),
            window: hostWindow
        ) else {
            isPresented = false
            return
        }
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
