//
//  ImportFromAppPreviewStep.swift
//  TablePro
//

import SwiftUI

struct ImportFromAppPreviewStep: View {
    let preview: ConnectionImportPreview
    let sourceName: String
    let onBack: () -> Void
    var onImported: ((Int) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<UUID> = []
    @State private var duplicateResolutions: [UUID: ImportResolution] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ConnectionImportPreviewList(
                items: preview.items,
                selectedIds: $selectedIds,
                duplicateResolutions: $duplicateResolutions
            )
            Divider()
            footer
        }
        .onAppear { selectReadyItems() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(String(format: String(localized: "Import from %@"), sourceName))
                .font(.body.weight(.semibold))
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(String(localized: "Back")) { onBack() }

            Text("\(selectedIds.count) of \(preview.items.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(String(localized: "Import")) { performImport() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIds.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func selectReadyItems() {
        for item in preview.items {
            switch item.status {
            case .ready, .warnings:
                selectedIds.insert(item.id)
            case .duplicate:
                break
            }
        }
    }

    private func performImport() {
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

        if preview.envelope.credentials != nil {
            ConnectionExportService.restoreCredentials(
                from: preview.envelope,
                connectionIdMap: result.connectionIdMap
            )
        }

        dismiss()
        onImported?(result.importedCount)
    }
}
