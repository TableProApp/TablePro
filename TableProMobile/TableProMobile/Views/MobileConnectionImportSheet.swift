import SwiftUI
import TableProImport
import TableProModels

struct MobileConnectionImportSheet: View {
    let fileURL: URL
    var onImported: ((Int) -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var preview: ConnectionImportPreview?
    @State private var selectedIds: Set<UUID> = []
    @State private var resolutions: [UUID: ImportResolution] = [:]
    @State private var encryptedData: Data?
    @State private var passphrase = ""
    @State private var passphraseError: String?
    @State private var wasEncryptedImport = false

    private enum Phase: Equatable {
        case loading
        case passphrase
        case preview
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Import Connections"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if phase == .preview {
                            Button(String(localized: "Import")) { performImport() }
                                .disabled(selectedIds.isEmpty)
                        }
                    }
                }
        }
        .task { await loadFile() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView().controlSize(.large)
        case .passphrase:
            passphraseView
        case .failed(let message):
            ContentUnavailableView {
                Label(String(localized: "Can't Import"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .preview:
            previewList
        }
    }

    private var passphraseView: some View {
        Form {
            Section {
                SecureField(String(localized: "Passphrase"), text: $passphrase)
                    .textContentType(.password)
                    .onSubmit { Task { await decrypt() } }
            } header: {
                Text("This file is encrypted")
            } footer: {
                if let passphraseError {
                    Text(passphraseError).foregroundStyle(.red)
                } else {
                    Text("Enter the passphrase to decrypt and import connections.")
                }
            }
            Button(String(localized: "Decrypt")) { Task { await decrypt() } }
                .disabled(passphrase.isEmpty)
        }
    }

    @ViewBuilder
    private var previewList: some View {
        if let preview {
            List {
                ForEach(preview.items) { item in
                    row(for: item)
                }
            }
        }
    }

    private func row(for item: ImportItem) -> some View {
        let isSelected = selectedIds.contains(item.id)
        return HStack(spacing: 12) {
            Button {
                toggle(item.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    DatabaseIconView(type: DatabaseType(rawValue: item.connection.type), size: 18)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.connection.name)
                            .lineLimit(1)
                        Text(subtitle(for: item))
                            .font(.caption)
                            .foregroundStyle(statusColor(for: item.status))
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if case .duplicate(let existingId, _) = item.status, isSelected {
                Picker("", selection: resolutionBinding(for: item)) {
                    Text(String(localized: "As Copy")).tag(ImportResolution.importAsCopy)
                    Text(String(localized: "Replace")).tag(ImportResolution.replace(existingId: existingId))
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func subtitle(for item: ImportItem) -> String {
        switch item.status {
        case .ready:
            return "\(item.connection.host):\(item.connection.port)"
        case .duplicate:
            return String(localized: "Already exists")
        case .warnings(let messages):
            return messages.first ?? "\(item.connection.host):\(item.connection.port)"
        }
    }

    private func statusColor(for status: ImportItemStatus) -> Color {
        switch status {
        case .ready: return .secondary
        case .duplicate: return .orange
        case .warnings: return .orange
        }
    }

    // MARK: - State helpers

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func resolutionBinding(for item: ImportItem) -> Binding<ImportResolution> {
        Binding(
            get: { resolutions[item.id] ?? .importAsCopy },
            set: { resolutions[item.id] = $0 }
        )
    }

    // MARK: - Actions

    private func loadFile() async {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: fileURL)
            if ConnectionExportCrypto.isEncrypted(data) {
                encryptedData = data
                phase = .passphrase
                return
            }
            let envelope = try ConnectionImportDecoder.decodeData(data)
            applyPreview(IOSConnectionImportService.analyze(envelope, appState: appState))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func decrypt() async {
        guard let data = encryptedData, !passphrase.isEmpty else { return }
        do {
            let envelope = try ConnectionImportDecoder.decodeEncryptedData(data, passphrase: passphrase)
            wasEncryptedImport = true
            applyPreview(IOSConnectionImportService.analyze(envelope, appState: appState))
        } catch {
            passphraseError = error.localizedDescription
            passphrase = ""
        }
    }

    private func applyPreview(_ result: ConnectionImportPreview) {
        preview = result
        for item in result.items {
            switch item.status {
            case .ready, .warnings:
                selectedIds.insert(item.id)
            case .duplicate:
                break
            }
        }
        phase = .preview
    }

    private func performImport() {
        guard let preview else { return }
        var resolved: [UUID: ImportResolution] = [:]
        for item in preview.items {
            if selectedIds.contains(item.id) {
                switch item.status {
                case .ready, .warnings:
                    resolved[item.id] = .importNew
                case .duplicate:
                    resolved[item.id] = resolutions[item.id] ?? .importAsCopy
                }
            } else {
                resolved[item.id] = .skip
            }
        }

        let result = IOSConnectionImportService.performImport(preview, resolutions: resolved, appState: appState)
        if wasEncryptedImport, preview.envelope.credentials != nil {
            IOSConnectionImportService.restoreCredentials(
                from: preview.envelope,
                connectionIdMap: result.connectionIdMap,
                secureStore: appState.secureStore
            )
        }
        onImported?(result.importedCount)
        dismiss()
    }
}
