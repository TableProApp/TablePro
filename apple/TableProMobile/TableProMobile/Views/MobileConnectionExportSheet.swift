import SwiftUI
import TableProImport
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
    @State private var includeSavedQueries = true
    @State private var includeGlobalSavedQueries = false
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var error: String?
    @State private var shareItem: IdentifiableURL?
    @State private var exportedURL: URL?
    @State private var isExporting = false

    private var canExport: Bool {
        guard includePasswords else { return true }
        return !passphrase.isEmpty && passphrase == confirmPassphrase
    }

    private var savedQueryCounts: SavedQueryCounts? {
        IOSConnectionExportService.savedQueryCounts(for: connections, appState: appState)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(connectionCountLabel)
                        .foregroundStyle(.secondary)
                }

                savedQueriesSection(savedQueryCounts)

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
            .disabled(isExporting)
            .navigationTitle(Text("Export Connections"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button(String(localized: "Export")) { isExporting = true }
                            .disabled(!canExport || connections.isEmpty)
                    }
                }
            }
            .task(id: isExporting) {
                guard isExporting else { return }
                await export()
                isExporting = false
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

    // Unreadable counts keep the toggle, so the export fails with a reason instead of dropping the queries.
    private static func offersSavedQueries(_ counts: SavedQueryCounts?) -> Bool {
        counts.map { $0.connectionScoped + $0.global > 0 } ?? true
    }

    @ViewBuilder
    private func savedQueriesSection(_ counts: SavedQueryCounts?) -> some View {
        if Self.offersSavedQueries(counts) {
            Section {
                Toggle(String(localized: "Include Saved Queries"), isOn: $includeSavedQueries)
                if let counts, counts.global > 0 {
                    Toggle(String(localized: "Also include global saved queries"), isOn: $includeGlobalSavedQueries)
                        .disabled(!includeSavedQueries)
                }
            } footer: {
                if let counts {
                    Text(Self.savedQueriesFooter(counts))
                }
            }
        }
    }

    private static func savedQueriesFooter(_ counts: SavedQueryCounts) -> String {
        var sentences: [String] = []
        if counts.connectionScoped == 1 {
            sentences.append(String(localized: "1 saved query that belongs to these connections, with its folder and keyword."))
        } else if counts.connectionScoped > 1 {
            sentences.append(String(
                format: String(localized: "%d saved queries that belong to these connections, with their folders and keywords."),
                counts.connectionScoped
            ))
        }
        if counts.global == 1 {
            sentences.append(String(localized: "1 saved query that every connection shows."))
        } else if counts.global > 1 {
            sentences.append(String(format: String(localized: "%d saved queries that every connection shows."), counts.global))
        }
        sentences.append(String(localized: "Saved queries are written as readable text unless the file is encrypted."))
        return sentences.joined(separator: " ")
    }

    private var connectionCountLabel: String {
        connections.count == 1
            ? String(localized: "1 connection will be exported.")
            : String(format: String(localized: "%d connections will be exported."), connections.count)
    }

    private func export() async {
        error = nil
        do {
            let includesSavedQueries = Self.offersSavedQueries(savedQueryCounts) && includeSavedQueries
            let data = try await IOSConnectionExportService.exportData(
                connections: connections,
                appState: appState,
                includeCredentials: includePasswords,
                includeSavedQueries: includesSavedQueries,
                includeGlobalSavedQueries: includesSavedQueries && includeGlobalSavedQueries,
                passphrase: includePasswords ? passphrase : nil
            )
            try Task.checkCancellation()
            let filename = IOSConnectionExportService.suggestedFilename(for: connections)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            exportedURL = url
            shareItem = IdentifiableURL(url: url)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}
