//
//  BackupDatabaseFlow.swift
//  TablePro
//
//  Top-level sheet for the Backup Dump menu item. Reuses
//  `DatabaseSwitcherSheet` in `.backup` mode to pick the database,
//  then drives an NSSavePanel sub-sheet and the consolidated
//  `NativeDumpService` progress flow.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackupDatabaseFlow: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection

    @State private var backupStartedAt: ContinuousClock.Instant?
    @State private var backupDatabase: String?
    let initialDatabase: String

    @State private var service = NativeDumpService(kind: .backup)
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
    private var serviceState: NativeDumpState { service.state }

    private func handleServiceStateChange(_ state: NativeDumpState) {
        switch state {
        case .running(let database, _, _, let totalBytes):
            phase = .running(database: database, totalBytes: totalBytes)
            /// Only on the way in. `startByteSizePolling` re-emits `.running` every 250ms with a
            /// fresh byte count, so assigning here unconditionally restarted the clock four times
            /// a second and a twenty minute dump reported as under a second, which the threshold
            /// then suppressed. Backups would have notified essentially never.
            if backupStartedAt == nil {
                backupStartedAt = .now
                backupDatabase = database
            }
        case .finished(let database, let fileURL, let bytes):
            phase = .finished(database: database, destination: fileURL, bytes: bytes)
            reportBackupFinished(.succeeded(OperationSummary(fileURL: fileURL)), database: database)
        case .failed(let message):
            phase = .failed(message: message)
            reportBackupFinished(.failed(reason: message), database: backupDatabase)
        case .cancelled:
            phase = .cancelled
            backupStartedAt = nil
            backupDatabase = nil
        case .idle, .cancelling:
            break
        }
    }

    private func reportBackupFinished(_ outcome: OperationOutcome, database: String?) {
        guard let startedAt = backupStartedAt else { return }
        backupStartedAt = nil
        backupDatabase = nil
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .backup,
                owner: .connection(connection.id),
                connectionId: connection.id,
                connectionName: connection.name,
                databaseName: database,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }

    private func promptForDestination(database: String) async {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false
        let archiveExtension = NativeDumpRegistry.descriptor(for: connection.type)?
            .archiveFormat.fileExtension ?? "dump"
        savePanel.allowedContentTypes = [UTType(filenameExtension: archiveExtension) ?? .data]
        savePanel.nameFieldStringValue = Self.defaultFilename(database: database, type: connection.type)
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

        guard await confirmPasswordExposureIfNeeded() else {
            phase = .pickDatabase
            return
        }

        phase = .running(database: database, totalBytes: nil)

        let totalBytes = await NativeDumpService.estimatedDatabaseSize(
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

    /// One tool, `sqlpackage`, takes a password only in its argument list, where `ps` can read
    /// it. The user is told before it runs rather than after, because the exposure lasts as long
    /// as the dump and there is no other channel to move it to.
    @MainActor
    private func confirmPasswordExposureIfNeeded() async -> Bool {
        guard let descriptor = NativeDumpRegistry.descriptor(for: connection.type),
              descriptor.exposesPasswordInArguments,
              !connection.username.isEmpty,
              ConnectionStorage.shared.loadPassword(for: connection.id) != nil else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "This tool takes your password on its command line.")
        alert.informativeText = String(localized: "SqlPackage has no other way to receive one, so while the dump runs the password is readable by other processes on this Mac. Windows or Entra authentication avoids it.")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = NSApp.keyWindow else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    /// The extension follows the engine's own archive format, so a MySQL dump is offered as `.sql`
    /// and a MongoDB one as `.archive` rather than all of them claiming PostgreSQL's `.dump`.
    private static func defaultFilename(database: String, type: DatabaseType) -> String {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let safeDB = database.isEmpty ? "database" : database
        let fileExtension = NativeDumpRegistry.descriptor(for: type)?.archiveFormat.fileExtension ?? "dump"
        return "\(safeDB)-\(timestamp).\(fileExtension)"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
