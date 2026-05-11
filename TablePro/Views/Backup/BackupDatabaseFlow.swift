//
//  BackupDatabaseFlow.swift
//  TablePro
//
//  Top-level sheet for the Backup Dump menu item. Reuses
//  `DatabaseSwitcherSheet` in `.backup` mode to pick the database,
//  then drives an NSSavePanel sub-sheet and the consolidated
//  `PostgresDumpService` progress flow.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupDatabaseFlow: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialDatabase: String

    @State private var service = PostgresDumpService(kind: .backup)
    @State private var phase: Phase = .pickDatabase

    private enum Phase: Equatable {
        case pickDatabase
        case running(database: String, totalBytes: Int64?)
        case finished(database: String, destination: URL, bytes: Int64)
        case failed(message: String)
        case cancelled
    }

    var body: some View {
        Group {
            switch phase {
            case .pickDatabase:
                pickerView
            case .running(let database, let totalBytes):
                BackupProgressSheet(
                    kind: .backup,
                    database: database,
                    bytesWritten: bytesWritten,
                    totalBytes: totalBytes,
                    isCancelling: service.state == .cancelling,
                    onCancel: { service.cancel() }
                )
            case .finished(let database, let destination, let bytes):
                BackupResultSheet(
                    kind: .backup,
                    outcome: .backupSuccess(database: database, destination: destination, bytes: bytes),
                    onClose: { isPresented = false },
                    onShowInFinder: { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                )
            case .failed(let message):
                BackupResultSheet(
                    kind: .backup,
                    outcome: .failure(message: message),
                    onClose: { isPresented = false },
                    onShowInFinder: nil
                )
            case .cancelled:
                BackupResultSheet(
                    kind: .backup,
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
        if case .running(_, _, let bytes, _) = service.state { return bytes }
        return 0
    }

    /// Hashable snapshot of `service.state` so SwiftUI's `onChange` fires on every transition.
    private var serviceState: PostgresDumpState { service.state }

    private func handleServiceStateChange(_ state: PostgresDumpState) {
        switch state {
        case .running(let database, _, _, let totalBytes):
            phase = .running(database: database, totalBytes: totalBytes)
        case .finished(let database, let fileURL, let bytes):
            phase = .finished(database: database, destination: fileURL, bytes: bytes)
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
        savePanel.title = String(localized: "Save Dump")
        savePanel.message = String(format: String(localized: "Choose where to save the dump of \u{201C}%@\u{201D}."), database)

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

        // Show progress immediately so the user gets feedback while we fetch
        // the database size estimate and locate pg_dump.
        phase = .running(database: database, totalBytes: nil)

        let totalBytes = await PostgresDumpService.estimatedDatabaseSize(
            connection: connection,
            database: database
        )

        do {
            try await service.start(
                connection: connection,
                database: database,
                fileURL: url,
                totalBytesEstimate: totalBytes
            )
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
