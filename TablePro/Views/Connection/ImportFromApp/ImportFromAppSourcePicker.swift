//
//  ImportFromAppSourcePicker.swift
//  TablePro
//

import AppKit
import SwiftUI

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

                if state.available {
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
        let icon = resolveAppIcon(bundleId: importer.appBundleIdentifier)
        if let icon {
            Image(nsImage: icon)
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
            Text("Read saved passwords from Keychain (requires permission)")
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

    private var isSelectedAvailable: Bool {
        guard let selectedId else { return false }
        return importerStates.first { $0.importer.id == selectedId }?.available ?? false
    }

    // MARK: - Actions

    private func loadStates() {
        Task.detached(priority: .userInitiated) {
            let importers = ForeignAppImporterRegistry.all
            var states: [(importer: any ForeignAppImporter, available: Bool, count: Int)] = []
            for importer in importers {
                let available = importer.isAvailable()
                let count = available ? importer.connectionCount() : 0
                states.append((importer: importer, available: available, count: count))
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
        guard let selectedId,
              let state = importerStates.first(where: { $0.importer.id == selectedId }),
              state.available else { return }
        onSelect(state.importer, includePasswords)
    }

    private func resolveAppIcon(bundleId: String) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}
