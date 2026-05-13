//
//  ImportFromAppSheet.swift
//  TablePro
//

import AppKit
import SwiftUI

struct ImportFromAppSheet: View {
    var onImported: ((Int) -> Void)?
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case sourcePicker
        case loading(sourceName: String)
        case preview(ConnectionImportPreview, String, Bool)
        case error(String)
    }

    @State private var step: Step = .sourcePicker
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch step {
            case .sourcePicker:
                ImportFromAppSourcePicker(
                    onSelect: { importer, includePasswords in
                        beginImport(importer: importer, includePasswords: includePasswords)
                    },
                    onCancel: { dismiss() }
                )

            case .loading(let sourceName):
                loadingView(sourceName: sourceName)

            case .preview(let preview, let sourceName, let credentialsAborted):
                ImportFromAppPreviewStep(
                    preview: preview,
                    sourceName: sourceName,
                    credentialsAborted: credentialsAborted,
                    onBack: { step = .sourcePicker },
                    onImported: onImported
                )

            case .error(let message):
                errorView(message)
            }
        }
        .frame(width: 520, height: 440)
    }

    // MARK: - Loading View

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

    // MARK: - Error View

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

    // MARK: - Actions

    private func beginImport(importer: any ForeignAppImporter, includePasswords: Bool) {
        if includePasswords, !confirmKeychainPrompts(for: importer) {
            return
        }
        startImport(importer: importer, includePasswords: includePasswords)
    }

    private func confirmKeychainPrompts(for importer: any ForeignAppImporter) -> Bool {
        let count = importer.connectionCount()
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
        alert.informativeText = String(format: template, importer.displayName, count)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func startImport(importer: any ForeignAppImporter, includePasswords: Bool) {
        step = .loading(sourceName: importer.displayName)

        importTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try importer.importConnections(includePasswords: includePasswords)
                try Task.checkCancellation()
                let preview = await ConnectionExportService.analyzeImport(result.envelope)
                try Task.checkCancellation()
                await MainActor.run {
                    step = .preview(preview, result.sourceName, result.credentialsAborted)
                    importTask = nil
                }
            } catch is CancellationError {
                await MainActor.run { importTask = nil }
            } catch {
                await MainActor.run {
                    step = .error(error.localizedDescription)
                    importTask = nil
                }
            }
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        dismiss()
    }
}
