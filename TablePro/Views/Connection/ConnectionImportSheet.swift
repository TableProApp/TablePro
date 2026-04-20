//
//  ConnectionImportSheet.swift
//  TablePro
//
//  Sheet for previewing and importing connections from a .tablepro file.
//

import SwiftUI
import UniformTypeIdentifiers

struct ConnectionImportSheet: View {
    let fileURL: URL
    var onImported: ((Int) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ConnectionImportPreview?
    @State private var error: String?
    @State private var isLoading = true
    @State private var selectedIds: Set<UUID> = []
    @State private var duplicateResolutions: [UUID: ImportResolution] = [:]
    @State private var encryptedData: Data?
    @State private var passphrase = ""
    @State private var passphraseError: String?
    @State private var isDecrypting = false
    @State private var wasEncryptedImport = false

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                loadingView
            } else if let error {
                errorView(error)
            } else if encryptedData != nil {
                passphraseView
            } else if let preview {
                header(preview)
                Divider()
                previewList(preview)
                Divider()
                footer(preview)
            }
        }
        .frame(width: 500, height: 400)
        .onAppear { loadFile() }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Spacer()
        }
        .frame(height: 200)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            HStack {
                Spacer()
                Button(String(localized: "OK")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .padding(.horizontal)
    }

    // MARK: - Header

    private func header(_ preview: ConnectionImportPreview) -> some View {
        HStack {
            Text(String(localized: "Import Connections"))
                .font(.body.weight(.semibold))
            Text("(\(fileURL.lastPathComponent))")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle(String(localized: "Select All"), isOn: Binding(
                get: { selectedIds.count == preview.items.count && !preview.items.isEmpty },
                set: { newValue in
                    if newValue {
                        selectedIds = Set(preview.items.map(\.id))
                    } else {
                        selectedIds.removeAll()
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    // MARK: - Preview List

    private func previewList(_ preview: ConnectionImportPreview) -> some View {
        List {
            ForEach(preview.items) { item in
                importItemRow(item)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func importItemRow(_ item: ImportItem) -> some View {
        let isSelected = selectedIds.contains(item.id)
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { newValue in
                    if newValue {
                        selectedIds.insert(item.id)
                    } else {
                        selectedIds.remove(item.id)
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            DatabaseType(rawValue: item.connection.type).iconImage
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.connection.name)
                        .font(.body)
                        .lineLimit(1)
                    if case .duplicate = item.status {
                        Text(String(localized: "duplicate"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: .quaternaryLabelColor))
                            )
                    }
                }
                HStack(spacing: 0) {
                    Text("\(item.connection.host):\(String(item.connection.port))")
                    warningText(for: item.status)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if case .duplicate = item.status, isSelected {
                Picker("", selection: Binding(
                    get: { duplicateResolutions[item.id] ?? .importAsCopy },
                    set: { duplicateResolutions[item.id] = $0 }
                )) {
                    Text(String(localized: "As Copy")).tag(ImportResolution.importAsCopy)
                    if case .duplicate(let existing) = item.status {
                        Text(String(localized: "Replace")).tag(ImportResolution.replace(existingId: existing.id))
                    }
                    Text(String(localized: "Skip")).tag(ImportResolution.skip)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 110)
                .labelsHidden()
            } else {
                statusIcon(for: item.status)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(for status: ImportItemStatus) -> some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .warnings:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color(nsColor: .systemYellow))
        case .duplicate:
            EmptyView()
        }
    }

    @ViewBuilder
    private func warningText(for status: ImportItemStatus) -> some View {
        if case .warnings(let messages) = status, let first = messages.first {
            Text(" — \(first)")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Passphrase

    private var passphraseView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("This file is encrypted")
                .font(.body.weight(.semibold))

            Text("Enter the passphrase to decrypt and import connections.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField(String(localized: "Passphrase"), text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { decryptFile() }

            if let passphraseError {
                Text(passphraseError)
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }

            Spacer()

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Decrypt")) { decryptFile() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty || isDecrypting)
            }
            .padding(12)
        }
        .padding(.horizontal)
    }

    // MARK: - Footer

    private func footer(_ preview: ConnectionImportPreview) -> some View {
        HStack {
            Text("\(selectedIds.count) of \(preview.items.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Import")) {
                performImport(preview)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIds.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func loadFile() {
        let url = fileURL
        Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url)

                if ConnectionExportCrypto.isEncrypted(data) {
                    await MainActor.run {
                        encryptedData = data
                        isLoading = false
                    }
                    return
                }

                let envelope = try ConnectionExportService.decodeData(data)
                let result = await ConnectionExportService.analyzeImport(envelope)
                await MainActor.run {
                    preview = result
                    selectReadyItems(result)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func decryptFile() {
        guard let data = encryptedData, !isDecrypting else { return }
        let currentPassphrase = passphrase
        isDecrypting = true

        Task.detached(priority: .userInitiated) {
            do {
                let envelope = try ConnectionExportService.decodeEncryptedData(data, passphrase: currentPassphrase)
                let result = await ConnectionExportService.analyzeImport(envelope)
                await MainActor.run {
                    passphraseError = nil
                    encryptedData = nil
                    wasEncryptedImport = true
                    preview = result
                    selectReadyItems(result)
                    isDecrypting = false
                }
            } catch {
                await MainActor.run {
                    passphraseError = error.localizedDescription
                    passphrase = ""
                    isDecrypting = false
                }
            }
        }
    }

    private func selectReadyItems(_ result: ConnectionImportPreview) {
        for item in result.items {
            switch item.status {
            case .ready, .warnings:
                selectedIds.insert(item.id)
            case .duplicate:
                break
            }
        }
    }

    private func performImport(_ preview: ConnectionImportPreview) {
        var resolutions: [UUID: ImportResolution] = [:]
        for item in preview.items {
            if selectedIds.contains(item.id) {
                switch item.status {
                case .ready, .warnings:
                    resolutions[item.id] = .importNew
                case .duplicate:
                    resolutions[item.id] = duplicateResolutions[item.id] ?? .importAsCopy
                }
            } else {
                resolutions[item.id] = .skip
            }
        }

        let result = ConnectionExportService.performImport(preview, resolutions: resolutions)

        // Only restore credentials from verified encrypted imports (not plaintext files)
        if wasEncryptedImport, preview.envelope.credentials != nil {
            ConnectionExportService.restoreCredentials(
                from: preview.envelope,
                connectionIdMap: result.connectionIdMap
            )
        }

        dismiss()
        onImported?(result.importedCount)
    }
}
