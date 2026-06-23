//
//  ImportFromAppSourcePicker.swift
//  TablePro
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportFromAppSourcePicker: View {
    let onSelect: (any ForeignAppImporter, Bool) -> Void
    let onCancel: () -> Void

    @State private var selectedId: String?
    @State private var includePasswords = true
    @State private var importerStates: [(importer: any ForeignAppImporter, available: Bool, count: Int)] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sourceList
            Divider()
            passwordToggle
            Divider()
            footer
        }
        .onAppear { loadStates() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Import from Other App")
                .font(.body.weight(.semibold))
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    // MARK: - Source List

    private var sourceList: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            } else {
                List(selection: $selectedId) {
                    ForEach(importerStates, id: \.importer.id) { state in
                        sourceRow(state)
                            .tag(state.importer.id)
                            .disabled(!state.available)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ state: (importer: any ForeignAppImporter, available: Bool, count: Int)) -> some View {
        HStack(spacing: 12) {
            appIcon(for: state.importer)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.importer.displayName)
                    .font(.body)

                if state.importer.importFileTypes != nil {
                    Text(String(localized: "Choose an export file to import"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if state.available {
                    Text(
                        state.count == 1
                            ? String(localized: "1 connection found")
                            : String(format: String(localized: "%d connections found"), state.count)
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "Not installed"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func appIcon(for importer: any ForeignAppImporter) -> some View {
        if let appURL = importer.installedAppURL() {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: importer.symbolName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
    }

    // MARK: - Password Toggle

    private var passwordToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Include passwords", isOn: $includePasswords)
            Text(includePasswordsSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Continue")) { continueAction() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedId == nil || !isSelectedAvailable)
        }
        .padding(12)
    }

    // MARK: - Computed

    private var selectedImporter: (any ForeignAppImporter)? {
        importerStates.first { $0.importer.id == selectedId }?.importer
    }

    private var isSelectedAvailable: Bool {
        importerStates.first { $0.importer.id == selectedId }?.available ?? false
    }

    private var includePasswordsSubtitle: String {
        if selectedImporter?.readsPasswordsFromKeychain ?? true {
            return String(localized: "Read saved passwords from Keychain (requires permission)")
        }
        return String(localized: "Saved passwords are decrypted during import")
    }

    // MARK: - Actions

    private func loadStates() {
        Task.detached(priority: .userInitiated) {
            let importers = ForeignAppImporterRegistry.all
            let states: [(importer: any ForeignAppImporter, available: Bool, count: Int)] = importers.map { importer in
                let available = importer.isAvailable()
                let count = available ? importer.connectionCount() : 0
                return (importer: importer, available: available, count: count)
            }
            await MainActor.run {
                importerStates = states
                isLoading = false
                if selectedId == nil, let first = states.first(where: { $0.available }) {
                    selectedId = first.importer.id
                }
            }
        }
    }

    private func continueAction() {
        guard let state = importerStates.first(where: { $0.importer.id == selectedId }),
              state.available else { return }

        if state.importer.importFileTypes != nil {
            presentFilePicker(for: state.importer)
        } else {
            onSelect(state.importer, includePasswords)
        }
    }

    private func presentFilePicker(for importer: any ForeignAppImporter) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let types = importer.importFileTypes {
            panel.allowedContentTypes = types
        }
        panel.message = String(format: String(localized: "Choose a %@ export file to import"), importer.displayName)

        let includePasswords = includePasswords
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            var configured = importer
            configured.setSelectedFile(url)
            onSelect(configured, includePasswords)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
