//
//  ConnectionExportOptionsSheet.swift
//  TablePro
//

import SwiftUI
import TableProImport
import UniformTypeIdentifiers

struct ConnectionExportOptionsSheet: View {
    @ObservedObject private var licenseManager = LicenseManager.shared
    let connections: [DatabaseConnection]

    @Environment(\.dismiss) private var dismiss
    @State private var includeCredentials = false
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var exportDocument: ConnectionExportDocument?
    @State private var isExporting = false
    @State private var isPreparingExport = false
    @State private var exportError: String?

    private var isProAvailable: Bool {
        licenseManager.isFeatureAvailable(.encryptedExport)
    }

    private var passphraseState: ConnectionExportPassphraseState {
        ConnectionExportPassphraseState.evaluate(passphrase: passphrase, confirmation: confirmPassphrase)
    }

    private var canExport: Bool {
        guard includeCredentials else { return true }
        return passphraseState.allowsExport
    }

    private var defaultFilename: String {
        connections.count == 1 ? connections[0].name : String(localized: "Connections")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            options
                .padding(20)
                .disabled(isPreparingExport)

            Spacer(minLength: 0)

            Divider()

            footer
                .padding(16)
        }
        .frame(width: 440, height: 300)
        .task(id: isPreparingExport) {
            guard isPreparingExport else { return }
            await performExport()
            isPreparingExport = false
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .tableproConnectionShare,
            defaultFilename: defaultFilename
        ) { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                exportError = error.localizedDescription
                return
            }
            dismiss()
        }
        .alert(
            String(localized: "Export Failed"),
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) { exportError = nil }
        } message: {
            if let exportError {
                Text(exportError)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("Export Options")
                .font(.headline)
            Text(exportSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
    }

    private var exportSummary: String {
        connections.count == 1
            ? connections[0].name
            : String(format: String(localized: "%d connections"), connections.count)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Toggle("Include Credentials", isOn: $includeCredentials)
                        .toggleStyle(.checkbox)
                        .disabled(!isProAvailable)
                    if !isProAvailable {
                        ProBadge(feature: .encryptedExport)
                    }
                }
                Text("Off by default. Turn it on to encrypt saved passwords with a passphrase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if includeCredentials {
                passphraseFields
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var passphraseFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Passphrase")
                        .gridColumnAlignment(.trailing)
                    SecureField(String(localized: "8+ characters"), text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Confirm")
                        .gridColumnAlignment(.trailing)
                    SecureField(String(localized: "Re-enter passphrase"), text: $confirmPassphrase)
                        .textFieldStyle(.roundedBorder)
                }
            }

            validationMessage
                .frame(height: 16, alignment: .leading)
        }
    }

    @ViewBuilder
    private var validationMessage: some View {
        switch passphraseState {
        case .tooShort:
            warningLabel(String(localized: "Use at least 8 characters"))
        case .mismatch:
            warningLabel(String(localized: "Passphrases do not match"))
        case .empty, .incomplete, .ok:
            EmptyView()
        }
    }

    private func warningLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private var footer: some View {
        DialogFooter {
            if isPreparingExport {
                ProgressView()
                    .controlSize(.small)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Export…") { isPreparingExport = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport || isPreparingExport)
        }
    }

    private func performExport() async {
        do {
            let data = try await exportPayload()
            try Task.checkCancellation()
            passphrase = ""
            confirmPassphrase = ""
            exportDocument = ConnectionExportDocument(data: data)
            isExporting = true
        } catch is CancellationError {
            return
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportPayload() async throws -> Data {
        guard includeCredentials, isProAvailable else {
            return try ConnectionExportService.exportData(connections)
        }
        return try await ConnectionExportService.exportEncryptedData(connections, passphrase: passphrase)
    }
}
