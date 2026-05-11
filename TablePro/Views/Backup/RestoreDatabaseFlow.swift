//
//  RestoreDatabaseFlow.swift
//  TablePro
//
//  Sheet body for the Restore Dump menu item. Opens NSOpenPanel as a
//  sub-sheet on appear (symmetric with backup's NSSavePanel), then
//  presents the database picker, then drives `PostgresRestoreService`.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RestoreDatabaseFlow: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialDatabase: String

    @State private var service = PostgresDumpService(kind: .restore)
    @State private var phase: Phase = .needsSource
    @State private var sourceURL: URL?

    private enum Phase: Equatable {
        case needsSource
        case pickDatabase
        case running(database: String)
        case finished(database: String, source: URL)
        case failed(message: String)
        case cancelled
    }

    var body: some View {
        Group {
            switch phase {
            case .needsSource:
                // Placeholder while the open panel is presented as a sub-sheet.
                sourceLoading
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
        .onAppear {
            if phase == .needsSource {
                Task { await promptForSource() }
            }
        }
        .onChange(of: serviceState) { _, newState in
            handleServiceStateChange(newState)
        }
    }

    private var sourceLoading: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.regular)
            Text("Choose a dump file\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 420, height: 200)
        .background(Color(nsColor: .windowBackgroundColor))
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

    @ViewBuilder
    private var sourceBanner: some View {
        if let url = sourceURL {
            HStack(spacing: 8) {
                Image(systemName: "doc.zipper")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore from")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Change\u{2026}") {
                    Task { await promptForSource() }
                }
                .buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 420, alignment: .leading)
        }
    }

    /// Hashable snapshot of `service.state` so SwiftUI's `onChange` fires on every transition.
    private var serviceState: PostgresDumpState { service.state }

    private func handleServiceStateChange(_ state: PostgresDumpState) {
        switch state {
        case .running(let database, _, _, _):
            phase = .running(database: database)
        case .finished(let database, let fileURL, _):
            phase = .finished(database: database, source: fileURL)
        case .failed(let message):
            phase = .failed(message: message)
        case .cancelled:
            phase = .cancelled
        case .idle, .cancelling:
            break
        }
    }

    @MainActor
    private func promptForSource() async {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = Self.allowedDumpTypes
        openPanel.title = String(localized: "Choose Dump File")
        openPanel.prompt = String(localized: "Choose")
        openPanel.message = String(localized: "Select a backup file produced by pg_dump in custom archive format (.dump).")

        let window = NSApp.keyWindow
        let response: NSApplication.ModalResponse
        if let window {
            response = await openPanel.beginSheetModal(for: window)
        } else {
            response = openPanel.runModal()
        }
        guard response == .OK, let url = openPanel.url else {
            // Cancel from the very-first source pick closes the flow;
            // cancel from a Change… click leaves the existing source in place.
            if sourceURL == nil { isPresented = false }
            return
        }
        sourceURL = url
        if phase == .needsSource { phase = .pickDatabase }
    }

    private func startRestore(database: String) async {
        guard let source = sourceURL else { return }
        phase = .running(database: database)
        do {
            try await service.start(connection: connection, database: database, fileURL: source)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// File types accepted in the open panel. `.dump` is the convention for
    /// pg_dump custom archive output but plenty of files have generic extensions.
    private static var allowedDumpTypes: [UTType] {
        var types: [UTType] = [.data]
        if let dumpType = UTType(filenameExtension: "dump") {
            types.insert(dumpType, at: 0)
        }
        return types
    }
}
