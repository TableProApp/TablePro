//
//  DatabaseTypeChooserSheet.swift
//  TablePro
//

import SwiftUI

struct DatabaseTypeChooserSheet: View {
    let initialType: DatabaseType?
    let onSelected: (DatabaseType) -> Void
    let onCancel: () -> Void

    @State private var model = DatabaseTypeChooserModel()
    @Environment(\.dismiss) private var dismiss

    init(
        initialType: DatabaseType? = nil,
        onSelected: @escaping (DatabaseType) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.initialType = initialType
        self.onSelected = onSelected
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
        .onAppear {
            model.preselect(initialType)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Choose a Database"))
                .font(.headline)
            Text(String(localized: "Pick the type of database you want to connect to."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if model.groupedTypes.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: Binding(
                get: { model.highlightedType },
                set: { model.highlightedType = $0 }
            )) {
                ForEach(model.groupedTypes, id: \.category) { section in
                    Section {
                        ForEach(section.types, id: \.self) { type in
                            DatabaseTypeChooserRow(type: type)
                                .tag(type)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    commit(type)
                                }
                        }
                    } header: {
                        Text(section.category.displayName)
                    }
                }
            }
            .listStyle(.inset)
            .searchable(text: $model.searchText, placement: .toolbar)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(role: .cancel) {
                onCancel()
                dismiss()
            } label: {
                Text(String(localized: "Cancel"))
            }
            .keyboardShortcut(.cancelAction)

            Button {
                if let type = model.highlightedType {
                    commit(type)
                }
            } label: {
                Text(String(localized: "Continue"))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.highlightedType == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func commit(_ type: DatabaseType) {
        onSelected(type)
        dismiss()
    }
}

private struct DatabaseTypeChooserRow: View {
    let type: DatabaseType

    var body: some View {
        HStack(spacing: 12) {
            type.iconImage
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(type.rawValue)
                    .font(.body)
                if let tagline = type.tagline {
                    Text(tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if shouldShowNotInstalledBadge {
                Text(String(localized: "Not Installed"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
            }
        }
        .padding(.vertical, 4)
    }

    private var shouldShowNotInstalledBadge: Bool {
        type.isDownloadablePlugin && !PluginManager.shared.isDriverLoaded(for: type)
    }
}
