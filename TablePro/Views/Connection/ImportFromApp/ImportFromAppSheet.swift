//
//  ImportFromAppSheet.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProImport

struct ImportFromAppSheet: View {
    let onFinished: (ImportOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .sourcePicker
    @State private var pendingCollect: PendingCollect?

    private enum Step {
        case sourcePicker
        case loading(sourceName: String)
        case review(ImportPreview, title: String, banner: ImportReviewBanner?)
        case error(String)
    }

    private struct PendingCollect {
        let id = UUID()
        let importer: any ForeignAppImporter
        let request: ForeignImportRequest
    }

    var body: some View {
        Group {
            switch step {
            case .sourcePicker:
                ImportFromAppSourcePicker(
                    onSelect: { importer, request, inventory in
                        beginImport(importer: importer, request: request, inventory: inventory)
                    },
                    onCancel: { dismiss() }
                )

            case .loading(let sourceName):
                loadingView(sourceName: sourceName)

            case .review(let preview, let title, let banner):
                ImportReviewStep(
                    title: title,
                    banner: banner,
                    preview: preview,
                    onBack: { step = .sourcePicker },
                    onFinished: onFinished
                )

            case .error(let message):
                errorView(message)
            }
        }
        .importSheetFrame()
        .task(id: pendingCollect?.id) {
            guard let pending = pendingCollect else { return }
            await collect(pending)
        }
    }

    private func loadingView(sourceName: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(String(format: String(localized: "Reading connections from %@…"), sourceName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(String(localized: "If macOS asks for your login password, click Always Allow on each prompt."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { cancelImport() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            HStack {
                Button(String(localized: "Back")) { step = .sourcePicker }
                Spacer()
                Button(String(localized: "OK")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    nonisolated static func requiresKeychainConfirmation(includePasswords: Bool, importer: any ForeignAppImporter) -> Bool {
        includePasswords && importer.readsPasswordsFromKeychain
    }

    private func beginImport(importer: any ForeignAppImporter, request: ForeignImportRequest, inventory: ForeignAppInventory) {
        if Self.requiresKeychainConfirmation(includePasswords: request.includePasswords, importer: importer),
           !confirmKeychainPrompts(for: importer, connectionCount: inventory.connections) {
            return
        }
        step = .loading(sourceName: importer.displayName)
        pendingCollect = PendingCollect(importer: importer, request: request)
    }

    private func confirmKeychainPrompts(for importer: any ForeignAppImporter, connectionCount: Int) -> Bool {
        let template = String(
            localized: """
                Importing passwords from %1$@ reads up to %2$d keychain items. \
                macOS prompts for your login password once per item because each is owned by %1$@. \
                Click Always Allow on each prompt to grant TablePro permanent access. \
                Cancel any prompt to skip the rest.
                """
        )
        let alert = NSAlert()
        alert.messageText = String(localized: "macOS will ask for your login password")
        alert.informativeText = String(format: template, importer.displayName, connectionCount)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func collect(_ pending: PendingCollect) async {
        defer {
            if pendingCollect?.id == pending.id {
                pendingCollect = nil
            }
        }
        do {
            let collected = try await Self.collect(from: pending.importer, request: pending.request)
            try Task.checkCancellation()
            let preview = try await ImportReviewLoader.preview(of: collected)
            try Task.checkCancellation()
            step = .review(
                preview,
                title: String(format: String(localized: "Import from %@"), pending.importer.displayName),
                banner: collected.credentialsAborted ? .credentialsNotRead : nil
            )
        } catch is CancellationError {
            return
        } catch {
            step = .error(ImportReviewLoader.message(for: error))
        }
    }

    @concurrent
    nonisolated private static func collect(
        from importer: any ForeignAppImporter,
        request: ForeignImportRequest
    ) async throws -> CollectedImport {
        try importer.collect(request)
    }

    private func cancelImport() {
        pendingCollect = nil
        dismiss()
    }
}
