//
//  BackupDatabaseFlow.swift
//  TablePro
//
//  Top-level sheet for the Backup Dump menu item: one plan sheet that picks
//  databases, objects, format and destination, then a batch that writes one
//  file per database through `NativeDumpService`.
//

import AppKit
import SwiftUI

struct BackupDatabaseFlow: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialDatabase: String
    /// Databases the sidebar had selected when Back Up was chosen. Empty means the sheet falls back
    /// to the database the window is browsing.
    var preselectedDatabases: Set<String> = []

    @State private var model: BackupScopeModel
    @State private var batch = NativeDumpBatch()
    @State private var phase: Phase = .plan
    @State private var formatId: String
    @State private var directory: URL
    @State private var startedAt: ContinuousClock.Instant?

    /// The window this flow is hosted in. `NSApp.keyWindow` at the moment a panel is presented is
    /// whatever is frontmost, which during a sheet transition is not this flow's own window.
    @State private var hostWindow: NSWindow?

    @AppStorage(PreferenceKeys.lastBackupDirectory.name, store: AppStorageEnvironment.shared.defaults)
    private var lastBackupDirectory = ""

    private enum Phase: Equatable {
        case plan
        case running
        case finished(outcomes: [NativeDumpBatchOutcome], directory: URL)
    }

    init(
        isPresented: Binding<Bool>,
        connection: DatabaseConnection,
        initialDatabase: String,
        preselectedDatabases: Set<String> = []
    ) {
        self._isPresented = isPresented
        self.connection = connection
        self.initialDatabase = initialDatabase
        self.preselectedDatabases = preselectedDatabases
        let formats = NativeDumpRegistry.formats(for: connection.type)
        self._formatId = State(initialValue: formats.first?.id ?? "default")
        self._model = State(
            wrappedValue: BackupScopeModel(
                connection: connection,
                objectScope: NativeDumpRegistry.descriptor(for: connection.type)?.objectScope
                    ?? .unsupported(reason: "")
            )
        )
        let stored = AppStorageEnvironment.shared.defaults
            .string(forKey: PreferenceKeys.lastBackupDirectory.name) ?? ""
        self._directory = State(initialValue: Self.resolveDirectory(stored))
    }

    private var formats: [NativeDumpDescriptor.ArchiveFormat] {
        NativeDumpRegistry.formats(for: connection.type)
    }

    private var format: NativeDumpDescriptor.ArchiveFormat {
        formats.first { $0.id == formatId } ?? formats.first
            ?? NativeDumpDescriptor.ArchiveFormat(fileExtension: "dump", contentDescription: "")
    }

    var body: some View {
        Group {
            switch phase {
            case .plan:
                BackupPlanSheet(
                    model: model,
                    formats: formats,
                    formatId: $formatId,
                    directory: $directory,
                    onCancel: { isPresented = false },
                    onStart: { Task { await start() } }
                )
            case .running:
                BackupProgressSheet(
                    kind: .backup,
                    database: batch.state.currentDatabase,
                    bytesWritten: batch.state.bytesProcessed,
                    totalBytes: batch.state.totalBytes,
                    isCancelling: batch.state.isCancelling,
                    itemIndex: batch.state.currentIndex,
                    itemTotal: batch.state.total,
                    onCancel: { batch.cancel() }
                )
            case .finished(let outcomes, let directory):
                BackupResultSheet(
                    kind: .backup,
                    outcome: .batch(outcomes: outcomes, directory: directory),
                    onClose: { isPresented = false },
                    onShowInFinder: {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            outcomes.filter(\.succeeded).map(\.destination)
                        )
                    }
                )
            }
        }
        .background { WindowAccessor { window in hostWindow = window } }
        .task {
            await model.loadDatabases(
                preselecting: preselectedDatabases,
                activeDatabase: initialDatabase.isEmpty ? nil : initialDatabase
            )
        }
    }

    // MARK: - Run

    @MainActor
    private func start() async {
        guard model.canRun else { return }
        guard await confirmPasswordExposureIfNeeded() else { return }

        let timestamp = NativeDumpDestination.timestamp(Date())
        let scopes = model.scopes()
        /// Named after what the tree showed, not after the engine's identity for it: a SQLite
        /// connection identifies its database by the file's whole path, and a dump called
        /// `_Users_me_Library_..._Chinook.sqlite-2026-09-06.sql` helps nobody.
        let plan = NativeDumpDestination.plan(
            databases: scopes.map(\.label),
            in: directory,
            timestamp: timestamp,
            fileExtension: format.fileExtension
        )

        var items: [NativeDumpBatchItem] = []
        for (index, entry) in scopes.enumerated() {
            let expanded = await BackupScopeLoader.expandDependents(
                entry.scope, connection: connection, database: entry.database
            )
            items.append(
                NativeDumpBatchItem(
                    database: entry.database,
                    scope: expanded,
                    destination: plan[index].url
                )
            )
        }

        startedAt = .now
        phase = .running
        await batch.run(connection: connection, items: items, formatId: formatId)
        lastBackupDirectory = directory.path(percentEncoded: false)
        phase = .finished(outcomes: batch.state.outcomes, directory: directory)
        report(batch.state.outcomes)
    }

    private func report(_ outcomes: [NativeDumpBatchOutcome]) {
        guard let startedAt else { return }
        self.startedAt = nil
        let failures = outcomes.filter { !$0.succeeded }
        let outcome: OperationOutcome
        if failures.isEmpty, let first = outcomes.first {
            outcome = .succeeded(
                OperationSummary(fileURL: outcomes.count == 1 ? first.destination : directory)
            )
        } else {
            outcome = .failed(
                reason: String(
                    format: String(localized: "%1$lld of %2$lld databases were not backed up."),
                    Int64(failures.count),
                    Int64(outcomes.count)
                )
            )
        }
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .backup,
                owner: .connection(connection.id),
                connectionId: connection.id,
                connectionName: connection.name,
                databaseName: outcomes.count == 1 ? outcomes.first?.database : nil,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }

    /// One tool, `sqlpackage`, takes a password only in its argument list, where `ps` can read it.
    /// The user is told before it runs rather than after, because the exposure lasts as long as the
    /// dump and there is no other channel to move it to.
    @MainActor
    private func confirmPasswordExposureIfNeeded() async -> Bool {
        guard let descriptor = NativeDumpRegistry.descriptor(for: connection.type, formatId: formatId),
              descriptor.exposesPasswordInArguments,
              !connection.username.isEmpty,
              ConnectionStorage.shared.loadPassword(for: connection.id) != nil else {
            return true
        }
        return await AlertHelper.confirm(
            title: String(localized: "This tool takes your password on its command line."),
            message: String(
                localized: """
                    SqlPackage has no other way to receive one, so while the dump runs the password \
                    is readable by other processes on this Mac. Windows or Entra authentication \
                    avoids it.
                    """),
            confirmButton: String(localized: "Continue"),
            window: hostWindow
        )
    }

    /// A folder the user can actually write to. A remembered path can be on a volume that is no
    /// longer mounted, and an open panel that starts nowhere opens at the last place the app used
    /// rather than at anything to do with backups.
    private static func resolveDirectory(_ stored: String) -> URL {
        if !stored.isEmpty {
            let url = URL(fileURLWithPath: stored)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
