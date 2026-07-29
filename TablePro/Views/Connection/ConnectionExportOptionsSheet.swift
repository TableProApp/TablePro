//
//  ConnectionExportOptionsSheet.swift
//  TablePro
//

import SwiftUI
import TableProImport
import UniformTypeIdentifiers

struct ConnectionExportOptionsSheet: View {
    let connections: [DatabaseConnection]

    @Environment(\.dismiss) private var dismiss
    @State private var includeCredentials = false
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var exportDocument: ConnectionExportDocument?
    @State private var isExporting = false
    @State private var exportError: String?

    private var isProAvailable: Bool {
        LicenseManager.shared.isFeatureAvailable(.encryptedExport)
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

            Spacer(minLength: 0)

            Divider()

            footer
                .padding(16)
        }
        .frame(width: 440, height: 300)
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
                        ProBadge()
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
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Export...") { performExport() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
        }
    }

    private func performExport() {
        do {
            let data = includeCredentials && isProAvailable
                ? try ConnectionExportService.exportEncryptedData(connections, passphrase: passphrase)
                : try ConnectionExportService.exportData(connections)
            passphrase = ""
            confirmPassphrase = ""
            exportDocument = ConnectionExportDocument(data: data)
            isExporting = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}
