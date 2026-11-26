//
//  ImportFromAppSourcePicker.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// Outlives the picker view, so Back from the review finds the scan, the selection and every toggle as left.
@MainActor
final class ForeignSourcePickerModel: ObservableObject {
    @Published private(set) var rows: [ForeignSourceRow] = []
    @Published private(set) var isLoading = true
    @Published var selectedId: String?
    @Published private var choices: [String: ForeignImportRequest] = [:]

    private let scan: @Sendable () async -> [ForeignSourceRow]

    init(scan: @escaping @Sendable () async -> [ForeignSourceRow] = { await ForeignSourceScanner.scan() }) {
        self.scan = scan
    }

    func load() async {
        guard isLoading else { return }
        let scanned = await scan()
        guard isLoading else { return }
        rows = scanned
        isLoading = false
        if selectedId == nil {
            selectedId = ForeignSourceRule.preselected(scanned.map(\.summary))
        }
    }

    var selectedRow: ForeignSourceRow? {
        rows.first { $0.id == selectedId }
    }

    func request(for row: ForeignSourceRow) -> ForeignImportRequest {
        choices[row.id] ?? Self.defaultRequest(for: row)
    }

    func setIncludePasswords(_ include: Bool, for row: ForeignSourceRow) {
        var request = request(for: row)
        request.includePasswords = include
        choices[row.id] = request
    }

    func setIncludeSavedQueries(_ include: Bool, for row: ForeignSourceRow) {
        var request = request(for: row)
        request.includeSavedQueries = include
        choices[row.id] = request
    }

    // Keychain passwords start off so a first import raises no prompt; saved queries start on only when there are some.
    nonisolated static func defaultRequest(for row: ForeignSourceRow) -> ForeignImportRequest {
        ForeignImportRequest(
            includePasswords: !row.importer.readsPasswordsFromKeychain,
            includeSavedQueries: offersSavedQueries(row.importer) && row.inventory.savedQueries > 0
        )
    }

    nonisolated static func offersSavedQueries(_ importer: any ForeignAppImporter) -> Bool {
        if case .unavailable = importer.savedQuerySupport { return false }
        return true
    }
}

struct ImportFromAppSourcePicker: View {
    let onSelect: (any ForeignAppImporter, ForeignImportRequest, ForeignAppInventory) -> Void
    let onCancel: () -> Void

    @StateObject private var model: ForeignSourcePickerModel

    init(
        model: @autoclosure @escaping () -> ForeignSourcePickerModel = ForeignSourcePickerModel(),
        onSelect: @escaping (any ForeignAppImporter, ForeignImportRequest, ForeignAppInventory) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: model())
        self.onSelect = onSelect
        self.onCancel = onCancel
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
        .task { await model.load() }
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
            if model.isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $model.selectedId) {
                    ForEach(model.rows) { row in
                        sourceRow(row)
                            .tag(row.id)
                            .disabled(row.availability != .available)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func sourceRow(_ row: ForeignSourceRow) -> some View {
        HStack(spacing: 12) {
            appIcon(for: row.importer)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.importer.displayName)
                    .font(.body)
                Group {
                    if row.picksFile {
                        Text(String(localized: "Choose an export file to import"))
                    } else {
                        switch row.availability {
                        case .available:
                            Text(Self.connectionsFound(row.inventory.connections))
                            if let queries = Self.savedQueriesFound(row.inventory.savedQueries) {
                                Text(queries)
                            }
                        case .notFound:
                            Text(String(localized: "Not installed"))
                        case .unreadable(let reason):
                            Label {
                                Text(verbatim: reason)
                                    .lineLimit(2)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                                    .accessibilityHidden(true)
                            }
                            .help(reason)
                        }
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
        let selected = model.selectedRow
        let request = selected.map { model.request(for: $0) }
        let offersSavedQueries = selected.map { ForeignSourcePickerModel.offersSavedQueries($0.importer) } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Include passwords", isOn: Binding(
                    get: { request?.includePasswords ?? false },
                    set: { include in
                        if let selected {
                            model.setIncludePasswords(include, for: selected)
                        }
                    }
                ))
                .disabled(selected == nil)
                Text(includePasswordsSubtitle(for: selected))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Include saved queries", isOn: Binding(
                    get: { offersSavedQueries && request?.includeSavedQueries == true },
                    set: { include in
                        if let selected {
                            model.setIncludeSavedQueries(include, for: selected)
                        }
                    }
                ))
                .disabled(!offersSavedQueries)
                if let caption = savedQueriesCaption(for: selected) {
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
                .disabled(model.selectedRow?.availability != .available)
        }
        .padding(12)
    }

    private func includePasswordsSubtitle(for row: ForeignSourceRow?) -> String {
        if row?.importer.readsPasswordsFromKeychain ?? true {
            return String(localized: "Read saved passwords from Keychain (requires permission)")
        }
        return String(localized: "Saved passwords are decrypted during import")
    }

    private func savedQueriesCaption(for row: ForeignSourceRow?) -> String? {
        switch row?.importer.savedQuerySupport {
        case .reads(let caption):
            caption
        case .unavailable(let reason):
            reason
        case nil:
            nil
        }
    }

    private func request(for row: ForeignSourceRow) -> ForeignImportRequest {
        let chosen = model.request(for: row)
        return ForeignImportRequest(
            includePasswords: chosen.includePasswords,
            includeSavedQueries: ForeignSourcePickerModel.offersSavedQueries(row.importer) && chosen.includeSavedQueries
        )
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

    private func continueAction() {
        guard let row = model.selectedRow, row.availability == .available else { return }
        if row.picksFile {
            presentFilePicker(for: row)
        } else {
            onSelect(row.importer, request(for: row), row.inventory)
        }
    }

    private func presentFilePicker(for row: ForeignSourceRow) {
        let importer = row.importer
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let types = importer.importFileTypes {
            panel.allowedContentTypes = types
        }
        panel.message = String(format: String(localized: "Choose a %@ export file to import"), importer.displayName)

        let selectedRequest = request(for: row)
        let inventory = row.inventory
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
