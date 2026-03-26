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
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ConnectionImportPreview?
    @State private var error: String?
    @State private var isLoading = true
    @State private var selectedIds: Set<UUID> = []
    @State private var duplicateResolutions: [UUID: ImportResolution] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Spacer()
            } else if let error {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else if let preview {
                previewList(preview)
                Divider()
                footer(preview)
            }
        }
        .frame(width: 480, height: 420)
        .onAppear { loadFile() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.down")
                .font(.title2)
                .foregroundStyle(.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Connections")
                    .font(.headline)
                Text(fileURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
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
        HStack(spacing: 10) {
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
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.connection.name)
                    .fontWeight(.semibold)
                Text("\(item.connection.host):\(String(item.connection.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge(for: item.status)
        }
        .padding(.vertical, 2)

        if case .duplicate = item.status, isSelected {
            duplicateResolutionPicker(for: item)
                .padding(.leading, 36)
        }
    }

    @ViewBuilder
    private func statusBadge(for status: ImportItemStatus) -> some View {
        switch status {
        case .ready:
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .warnings:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
        case .duplicate:
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func duplicateResolutionPicker(for item: ImportItem) -> some View {
        Picker(String(localized: "Action"), selection: Binding(
            get: { duplicateResolutions[item.id] ?? .skip },
            set: { duplicateResolutions[item.id] = $0 }
        )) {
            Text("Skip").tag(ImportResolution.skip)
            if case .duplicate(let existing) = item.status {
                Text("Replace Existing").tag(ImportResolution.replace(existingId: existing.id))
            }
            Text("Import as Copy").tag(ImportResolution.importAsCopy)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
    }

    // MARK: - Footer

    private func footer(_ preview: ConnectionImportPreview) -> some View {
        HStack {
            Text("\(selectedIds.count) of \(preview.items.count) connections selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Import")) {
                performImport(preview)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIds.isEmpty)
        }
        .padding()
    }

    // MARK: - Actions

    private func loadFile() {
        do {
            let envelope = try ConnectionExportService.decodeFile(at: fileURL)
            let result = ConnectionExportService.analyzeImport(envelope)
            preview = result

            // Pre-select non-duplicate items
            for item in result.items {
                switch item.status {
                case .ready, .warnings:
                    selectedIds.insert(item.id)
                case .duplicate:
                    break
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func performImport(_ preview: ConnectionImportPreview) {
        var resolutions: [UUID: ImportResolution] = [:]
        for item in preview.items {
            if selectedIds.contains(item.id) {
                switch item.status {
                case .ready, .warnings:
                    resolutions[item.id] = .importNew
                case .duplicate:
                    resolutions[item.id] = duplicateResolutions[item.id] ?? .skip
                }
            } else {
                resolutions[item.id] = .skip
            }
        }

        ConnectionExportService.performImport(preview, resolutions: resolutions)
        dismiss()
    }
}

// MARK: - ImportResolution + Hashable

extension ImportResolution: @retroactive Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .importNew:
            hasher.combine(0)
        case .skip:
            hasher.combine(1)
        case .replace(let id):
            hasher.combine(2)
            hasher.combine(id)
        case .importAsCopy:
            hasher.combine(3)
        }
    }

    static func == (lhs: ImportResolution, rhs: ImportResolution) -> Bool {
        switch (lhs, rhs) {
        case (.importNew, .importNew), (.skip, .skip), (.importAsCopy, .importAsCopy):
            return true
        case (.replace(let lhsId), .replace(let rhsId)):
            return lhsId == rhsId
        default:
            return false
        }
    }
}
