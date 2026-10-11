//
//  ImportFromAppSourcePicker.swift
//  TablePro
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportFromAppSourcePicker: View {
    let onSelect: (any ForeignAppImporter, ForeignImportRequest, ForeignAppInventory) -> Void
    let onCancel: () -> Void

    @State private var selectedId: String?
    @State private var includePasswords = true
    @State private var includeSavedQueries = true
    @State private var sources: [Source] = []
    @State private var isLoading = true

    struct Source: Sendable {
        let importer: any ForeignAppImporter
        let available: Bool
        let inventory: ForeignAppInventory
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sourceList
            Divider()
            options
            Divider()
            footer
        }
        .task { await loadSources() }
    }

    private var header: some View {
        HStack {
            Text("Import from Other App")
                .font(.body.weight(.semibold))
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private var sourceList: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedId) {
                    ForEach(sources, id: \.importer.id) { source in
                        sourceRow(source)
                            .tag(source.importer.id)
                            .disabled(!source.available)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func sourceRow(_ source: Source) -> some View {
        HStack(spacing: 12) {
            appIcon(for: source.importer)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.importer.displayName)
                    .font(.body)
                Group {
                    if source.importer.importFileTypes != nil {
                        Text(String(localized: "Choose an export file to import"))
                    } else if source.available {
                        Text(Self.connectionsFound(source.inventory.connections))
                        if let queries = Self.savedQueriesFound(source.inventory.savedQueries) {
                            Text(queries)
                        }
                    } else {
                        Text(String(localized: "Not installed"))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                .scaledToFit()
        } else {
            Image(systemName: importer.symbolName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Include passwords", isOn: $includePasswords)
                Text(includePasswordsSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Include saved queries", isOn: Binding(
                    get: { readsSavedQueries && includeSavedQueries },
                    set: { includeSavedQueries = $0 }
                ))
                .disabled(!readsSavedQueries)
                if let caption = savedQueriesCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Continue")) { continueAction() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSource?.available != true)
        }
        .padding(12)
    }

    private var selectedSource: Source? {
        sources.first { $0.importer.id == selectedId }
    }

    private var includePasswordsSubtitle: String {
        if selectedSource?.importer.readsPasswordsFromKeychain ?? true {
            return String(localized: "Read saved passwords from Keychain (requires permission)")
        }
        return String(localized: "Saved passwords are decrypted during import")
    }

    private var readsSavedQueries: Bool {
        if case .unavailable? = selectedSource?.importer.savedQuerySupport { return false }
        return true
    }

    private var savedQueriesCaption: String? {
        switch selectedSource?.importer.savedQuerySupport {
        case .reads(let caption):
            caption
        case .unavailable(let reason):
            reason
        case nil:
            nil
        }
    }

    private var request: ForeignImportRequest {
        ForeignImportRequest(includePasswords: includePasswords, includeSavedQueries: readsSavedQueries && includeSavedQueries)
    }

    static func connectionsFound(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 connection found")
            : String(format: String(localized: "%d connections found"), count)
    }

    static func savedQueriesFound(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? String(localized: "1 saved query found")
            : String(format: String(localized: "%d saved queries found"), count)
    }

    private func loadSources() async {
        guard isLoading else { return }
        let loaded = await Self.inventorySources()
        sources = loaded
        isLoading = false
        if selectedId == nil, let first = loaded.first(where: \.available) {
            selectedId = first.importer.id
        }
    }

    @concurrent
    nonisolated private static func inventorySources() async -> [Source] {
        ForeignAppImporterRegistry.all.map { importer in
            let available = importer.isAvailable()
            let inventory = available ? importer.inventory() : ForeignAppInventory(connections: 0, savedQueries: 0)
            return Source(importer: importer, available: available, inventory: inventory)
        }
    }

    private func continueAction() {
        guard let source = selectedSource, source.available else { return }
        if source.importer.importFileTypes != nil {
            presentFilePicker(for: source)
        } else {
            onSelect(source.importer, request, source.inventory)
        }
    }

    private func presentFilePicker(for source: Source) {
        let importer = source.importer
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let types = importer.importFileTypes {
            panel.allowedContentTypes = types
        }
        panel.message = String(format: String(localized: "Choose a %@ export file to import"), importer.displayName)

        let selectedRequest = request
        let inventory = source.inventory
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            var configured = importer
            configured.setSelectedFile(url)
            onSelect(configured, selectedRequest, inventory)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
