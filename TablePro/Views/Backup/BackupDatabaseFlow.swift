//
//  BackupDatabaseFlow.swift
//  TablePro
//
//  Top-level sheet for the Backup Database menu item. Reuses
//  `DatabaseSwitcherSheet` in `.backup` mode to pick the database,
//  then drives a NSSavePanel and the `PostgresBackupService` progress flow.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupDatabaseFlow: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialDatabase: String

    @State private var service = PostgresBackupService()
    @State private var phase: Phase

    private enum Phase: Equatable {
        case pickDatabase
        case running(database: String)
        case finished(database: String, destination: URL, bytes: Int64)
        case failed(message: String)
        case cancelled
    }

    init(isPresented: Binding<Bool>, connection: DatabaseConnection, initialDatabase: String) {
        self._isPresented = isPresented
        self.connection = connection
        self.initialDatabase = initialDatabase
        self._phase = State(initialValue: .pickDatabase)
    }

    var body: some View {
        Group {
            switch phase {
            case .pickDatabase:
                pickerView
            case .running(let database):
                BackupProgressSheet(
                    database: database,
                    bytesWritten: bytesWritten,
                    isCancelling: service.state == .cancelling,
                    onCancel: { service.cancel() }
                )
            case .finished(let database, let destination, let bytes):
                BackupResultSheet(
                    outcome: .success(database: database, destination: destination, bytes: bytes),
                    onClose: { isPresented = false },
                    onShowInFinder: { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                )
            case .failed(let message):
                BackupResultSheet(
                    outcome: .failure(message: message),
                    onClose: { isPresented = false },
                    onShowInFinder: nil
                )
            case .cancelled:
                BackupResultSheet(
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
        DatabaseSwitcherSheet(
            isPresented: $isPresented,
            mode: .backup,
            currentDatabase: initialDatabase,
            databaseType: connection.type,
            connectionId: connection.id,
            onSelect: { database in
                Task { await promptForDestination(database: database) }
            }
        )
    }

    private var bytesWritten: Int64 {
        if case .running(_, let bytes) = service.state { return bytes }
        return 0
    }

    /// Hashable snapshot of `service.state` so SwiftUI's `onChange` fires on every transition.
    private var serviceState: PostgresBackupService.State { service.state }

    private func handleServiceStateChange(_ state: PostgresBackupService.State) {
        switch state {
        case .running(let database, _):
            phase = .running(database: database)
        case .finished(let database, let destination, let bytes):
            phase = .finished(database: database, destination: destination, bytes: bytes)
        case .failed(let message):
            phase = .failed(message: message)
        case .cancelled:
            phase = .cancelled
        case .idle, .cancelling:
            break
        }
    }

    private func promptForDestination(database: String) async {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false
        savePanel.allowedContentTypes = [UTType(filenameExtension: "dump") ?? .data]
        savePanel.nameFieldStringValue = Self.defaultFilename(database: database)
        savePanel.title = String(localized: "Save Backup")
        savePanel.message = String(format: String(localized: "Choose where to save the backup of \u{201C}%@\u{201D}."), database)

        let window = NSApp.keyWindow
        let response: NSApplication.ModalResponse
        if let window {
            response = await savePanel.beginSheetModal(for: window)
        } else {
            response = savePanel.runModal()
        }

        guard response == .OK, let url = savePanel.url else {
            phase = .pickDatabase
            return
        }

        do {
            try await service.start(connection: connection, database: database, destination: url)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    private static func defaultFilename(database: String) -> String {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let safeDB = database.isEmpty ? "database" : database
        return "\(safeDB)-\(timestamp).dump"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
