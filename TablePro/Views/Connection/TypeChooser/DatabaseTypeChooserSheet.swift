//
//  DatabaseTypeChooserSheet.swift
//  TablePro
//

import SwiftUI

struct DatabaseTypeChooserSheet: View {
    let initialType: DatabaseType?
    let onSelected: (DatabaseType) -> Void
    let onImportFromURL: (() -> Void)?
    let onCancel: () -> Void

    @State private var model = DatabaseTypeChooserModel()
    @Environment(\.dismiss) private var dismiss

    init(
        initialType: DatabaseType? = nil,
        onSelected: @escaping (DatabaseType) -> Void,
        onImportFromURL: (() -> Void)? = nil,
        onCancel: @escaping () -> Void = {}
    ) {
        self.initialType = initialType
        self.onSelected = onSelected
        self.onImportFromURL = onImportFromURL
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
        .frame(width: 560, height: 460)
        .onAppear {
            model.preselect(initialType)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Choose a Database"))
                    .font(.headline)
                Text(String(localized: "Pick the type of database you want to connect to."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            /// Arrow keys are handed over by the search field's own `NSSearchFieldDelegate`, which
            /// is the only route: a focused field editor consumes them as `doCommandBySelector:`
            /// before `onMoveCommand` or `onKeyPress` can see them, and `searchFocused` is
            /// macOS 15. `onSubmit` stays unwired, or Return would commit through both the field
            /// editor and Continue's `.defaultAction`.
            NativeSearchField(
                text: $model.searchText,
                placeholder: String(localized: "Search"),
                onMoveUp: { model.moveHighlight(by: -1) },
                onMoveDown: { model.moveHighlight(by: 1) },
                accessibilityIdentifier: "database-type-chooser-search"
            )
            .frame(width: 180)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if model.groupedTypes.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(selection: $model.highlightedType) {
                    ForEach(model.groupedTypes, id: \.category) { section in
                        Section {
                            ForEach(section.types, id: \.self) { type in
                                DatabaseTypeChooserRow(
                                    type: type,
                                    isCurrent: type == initialType
                                )
                                .tag(type)
                                .contentShape(Rectangle())
                                .id(type)
                                .listRowSeparator(.hidden)
                            }
                        } header: {
                            Text(section.category.displayName)
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: DatabaseType.self) { _ in
                    EmptyView()
                } primaryAction: { selection in
                    if let type = selection.first { commit(type) }
                }
                .onAppear {
                    if let initialType {
                        proxy.scrollTo(initialType, anchor: .center)
                    }
                }
                .onChange(of: model.highlightedType) { _, highlighted in
                    guard let highlighted else { return }
                    proxy.scrollTo(highlighted)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let onImportFromURL {
                Button {
                    onImportFromURL()
                    dismiss()
                } label: {
                    Label(String(localized: "Import from URL…"), systemImage: "link")
                }
                .help(String(localized: "Paste a connection URL to detect type and pre-fill fields"))
            }

            Spacer()

            Button(String(localized: "Cancel")) {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Continue")) {
                if let type = model.highlightedType {
                    commit(type)
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.highlightedType == nil)
        }
        .padding(20)
    }

    private func commit(_ type: DatabaseType) {
        onSelected(type)
        dismiss()
    }
}

private struct DatabaseTypeChooserRow: View {
    let type: DatabaseType
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            /// The row's icon is decoration the name already carries, and left unhidden it
            /// publishes its own element, so VoiceOver reads "Cylinder Shape, Filled" ahead of the
            /// driver. `Image(decorative:)` cannot cover it, because `DatabaseType.iconImage` also
            /// returns an SF Symbol.
            type.iconImage
                .renderingMode(.template)
                .foregroundStyle(type.themeColor)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

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

            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }

            if shouldShowNotInstalledBadge {
                Text(String(localized: "Not Installed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shouldShowNotInstalledBadge: Bool {
        type.isDownloadablePlugin && !PluginManager.shared.isDriverInstalled(for: type)
    }
}
