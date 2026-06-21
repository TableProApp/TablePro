import SwiftUI
import TableProModels

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: URL { url }
}

struct MobileConnectionExportSheet: View {
    let connections: [DatabaseConnection]

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var includePasswords = false
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var error: String?
    @State private var shareItem: IdentifiableURL?
    @State private var exportedURL: URL?

    private var canExport: Bool {
        guard includePasswords else { return true }
        return !passphrase.isEmpty && passphrase == confirmPassphrase
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(connectionCountLabel)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(String(localized: "Include passwords"), isOn: $includePasswords)
                } footer: {
                    Text("Passwords are excluded by default. To include them, set a passphrase. The file is encrypted with it.")
                }

                if includePasswords {
                    Section {
                        SecureField(String(localized: "Passphrase"), text: $passphrase)
                            .textContentType(.newPassword)
                        SecureField(String(localized: "Confirm passphrase"), text: $confirmPassphrase)
                            .textContentType(.newPassword)
                    } footer: {
                        if !confirmPassphrase.isEmpty, passphrase != confirmPassphrase {
                            Text("Passphrases don't match.").foregroundStyle(.red)
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(Text("Export Connections"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Export")) { export() }
                        .disabled(!canExport || connections.isEmpty)
                }
            }
            .sheet(item: $shareItem, onDismiss: {
                if let exportedURL {
                    try? FileManager.default.removeItem(at: exportedURL)
                }
                dismiss()
            }) { item in
                ActivityViewController(items: [item.url])
            }
        }
    }

    private var connectionCountLabel: String {
        connections.count == 1
            ? String(localized: "1 connection will be exported.")
            : String(format: String(localized: "%d connections will be exported."), connections.count)
    }

    private func export() {
        do {
            let data = try IOSConnectionExportService.exportData(
                connections: connections,
                appState: appState,
                includeCredentials: includePasswords,
                passphrase: includePasswords ? passphrase : nil
            )
            let filename = IOSConnectionExportService.suggestedFilename(for: connections)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            exportedURL = url
            shareItem = IdentifiableURL(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
