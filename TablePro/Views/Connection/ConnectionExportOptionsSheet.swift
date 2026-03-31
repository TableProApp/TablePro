//
//  ConnectionExportOptionsSheet.swift
//  TablePro
//
//  Sheet for choosing export options before saving a .tablepro file.
//

import SwiftUI
import UniformTypeIdentifiers

struct ConnectionExportOptionsSheet: View {
    let connections: [DatabaseConnection]

    @Environment(\.dismiss) private var dismiss
    @State private var includeCredentials = false
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""

    private var isProAvailable: Bool {
        LicenseManager.shared.isFeatureAvailable(.encryptedExport)
    }

    private var canExport: Bool {
        if includeCredentials {
            return (passphrase as NSString).length >= 8 && passphrase == confirmPassphrase
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Export Options"))
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Toggle("Include Credentials", isOn: $includeCredentials)
                        .toggleStyle(.checkbox)
                        .disabled(!isProAvailable)

                    if !isProAvailable {
                        Text("Pro")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor)
                            )
                    }
                }

                if includeCredentials {
                    Text("Passwords will be encrypted with the passphrase you provide.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    SecureField("Passphrase (8+ characters)", text: $passphrase)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Confirm passphrase", text: $confirmPassphrase)
                        .textFieldStyle(.roundedBorder)

                    if !passphrase.isEmpty && !confirmPassphrase.isEmpty && passphrase != confirmPassphrase {
                        Text("Passphrases do not match")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export...") { performExport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func performExport() {
        let shouldEncrypt = includeCredentials && isProAvailable
        let capturedPassphrase = passphrase
        let capturedConnections = connections

        // Zero passphrase state before dismissing
        passphrase = ""
        confirmPassphrase = ""
        dismiss()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.tableproConnectionShare]
            let defaultName = capturedConnections.count == 1
                ? "\(capturedConnections[0].name).tablepro"
                : "Connections.tablepro"
            panel.nameFieldStringValue = defaultName
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }

            do {
                if shouldEncrypt {
                    try ConnectionExportService.exportConnectionsEncrypted(
                        capturedConnections,
                        to: url,
                        passphrase: capturedPassphrase
                    )
                } else {
                    try ConnectionExportService.exportConnections(capturedConnections, to: url)
                }
            } catch {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Export Failed"),
                    message: error.localizedDescription,
                    window: NSApp.keyWindow
                )
            }
        }
    }
}
