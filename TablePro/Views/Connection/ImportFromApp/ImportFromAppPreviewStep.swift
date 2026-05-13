//
//  ImportFromAppPreviewStep.swift
//  TablePro
//

import SwiftUI

struct ImportFromAppPreviewStep: View {
    let preview: ConnectionImportPreview
    let sourceName: String
    let credentialsAborted: Bool
    let onBack: () -> Void
    var onImported: ((Int) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<UUID> = []
    @State private var duplicateResolutions: [UUID: ImportResolution] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            if credentialsAborted {
                credentialsAbortedBanner
            }
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

    private var credentialsAbortedBanner: some View {
        Label {
            Text(String(localized: "Some passwords were not read. You can enter them in the connection editor after import."))
                .font(.caption)
        } icon: {
            Image(systemName: "key.slash")
                .foregroundStyle(Color(nsColor: .systemOrange))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .systemOrange).opacity(0.12))
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
