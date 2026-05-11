//
//  RestoreDatabaseFlow.swift
//  TablePro
//
//  Sheet body for the Restore Database menu item. The .dump file is
//  chosen up front (NSOpenPanel from MainContentCommandActions), so this
//  flow opens directly on `DatabaseSwitcherSheet` in `.restore` mode and
//  drives `PostgresRestoreService` through to a result.
//

import AppKit
import SwiftUI

struct RestoreDatabaseFlow: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialDatabase: String
    let sourceURL: URL

    @State private var service = PostgresRestoreService()
    @State private var phase: Phase = .pickDatabase

    private enum Phase: Equatable {
        case pickDatabase
        case running(database: String)
        case finished(database: String, source: URL)
        case failed(message: String)
        case cancelled
    }

    var body: some View {
        Group {
            switch phase {
            case .pickDatabase:
                pickerView
            case .running(let database):
                BackupProgressSheet(
                    kind: .restore,
                    database: database,
                    bytesWritten: 0,
                    isCancelling: service.state == .cancelling,
                    onCancel: { service.cancel() }
                )
            case .finished(let database, let source):
                BackupResultSheet(
                    kind: .restore,
                    outcome: .restoreSuccess(database: database, source: source),
                    onClose: { isPresented = false },
                    onShowInFinder: nil
                )
            case .failed(let message):
                BackupResultSheet(
                    kind: .restore,
                    outcome: .failure(message: message),
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
        .onChange(of: serviceState) { _, newState in
            handleServiceStateChange(newState)
        }
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
        .frame(width: 420, alignment: .leading)
    }

    /// Hashable snapshot of `service.state` so SwiftUI's `onChange` fires on every transition.
    private var serviceState: PostgresRestoreService.State { service.state }

    private func handleServiceStateChange(_ state: PostgresRestoreService.State) {
        switch state {
        case .running(let database, _):
            phase = .running(database: database)
        case .finished(let database, let source):
            phase = .finished(database: database, source: source)
        case .failed(let message):
            phase = .failed(message: message)
        case .cancelled:
            phase = .cancelled
        case .idle, .cancelling:
            break
        }
    }

    private func startRestore(database: String) async {
        // Show the progress sheet immediately so the user sees feedback while
        // pg_restore is being located and started.
        phase = .running(database: database)
        do {
            try await service.start(connection: connection, database: database, source: sourceURL)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }
}
