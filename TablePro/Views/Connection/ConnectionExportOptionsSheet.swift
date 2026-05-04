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
        VStack(spacing: 0) {
            Text(String(localized: "Export Options"))
                .font(.body.weight(.semibold))
                .padding(.vertical, 12)

            Divider()

            Form {
                Section {
                    HStack(spacing: 6) {
                        Toggle("Include Credentials", isOn: $includeCredentials)
                            .toggleStyle(.checkbox)
                            .disabled(!isProAvailable)
                        if !isProAvailable {
                            ProBadge()
                        }
                    }
                } footer: {
                    if includeCredentials {
                        Text("Passwords will be encrypted with the passphrase you provide.")
                    }
                }

                if includeCredentials {
                    Section {
                        LabeledContent(String(localized: "Passphrase")) {
                            SecureField(String(localized: "8+ characters"), text: $passphrase)
                        }
                        LabeledContent(String(localized: "Confirm")) {
                            SecureField(String(localized: "Re-enter passphrase"), text: $confirmPassphrase)
                        }
                    }

                    if !passphrase.isEmpty && !confirmPassphrase.isEmpty && passphrase != confirmPassphrase {
                        Section {
                            Label(String(localized: "Passphrases do not match"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color(nsColor: .systemOrange))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export...") { performExport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
            .padding(12)
        }
        .frame(width: 420)
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
            guard let window = NSApp.keyWindow else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }

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
                        window: window
                    )
                }
            }
        }
    }
}
