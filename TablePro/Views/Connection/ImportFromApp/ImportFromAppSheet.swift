//
//  ImportFromAppSheet.swift
//  TablePro
//

import SwiftUI

struct ImportFromAppSheet: View {
    var onImported: ((Int) -> Void)?
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case sourcePicker
        case loading
        case preview(ConnectionImportPreview, String)
        case error(String)
    }

    @State private var step: Step = .sourcePicker

    var body: some View {
        Group {
            switch step {
            case .sourcePicker:
                ImportFromAppSourcePicker(
                    onSelect: { importer, includePasswords in
                        startImport(importer: importer, includePasswords: includePasswords)
                    },
                    onCancel: { dismiss() }
                )

            case .loading:
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text("Reading connections...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }

            case .preview(let preview, let sourceName):
                ImportFromAppPreviewStep(
                    preview: preview,
                    sourceName: sourceName,
                    onBack: { step = .sourcePicker },
                    onImported: onImported
                )

            case .error(let message):
                errorView(message)
            }
        }
        .frame(width: 520, height: 440)
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

    private func startImport(importer: any ForeignAppImporter, includePasswords: Bool) {
        step = .loading

        Task.detached(priority: .userInitiated) {
            do {
                let result = try importer.importConnections(includePasswords: includePasswords)
                let preview = await ConnectionExportService.analyzeImport(result.envelope)
                await MainActor.run {
                    step = .preview(preview, result.sourceName)
                }
            } catch {
                await MainActor.run {
                    step = .error(error.localizedDescription)
                }
            }
        }
    }
}
