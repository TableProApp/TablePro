//
//  FavoriteEditDialog.swift
//  TablePro
//

import SwiftUI

/// Wrapper for `.sheet(item:)` to ensure the query is passed reliably
internal struct FavoriteDialogQuery: Identifiable {
    let id = UUID()
    let query: String
}

/// Dialog for creating or editing a SQL favorite
internal struct FavoriteEditDialog: View {
    @Environment(\.dismiss) private var dismiss

    let connectionId: UUID
    let favorite: SQLFavorite?
    let initialQuery: String?
    let folderId: UUID?
    let folders: [SQLFavoriteFolder]

    @State private var name: String
    @State private var query: String
    @StateObject private var keywordField = SQLFavoriteKeywordField()
    @State private var isGlobal: Bool
    @State private var selectedFolderId: UUID?
    @State private var isSaving = false
    @State private var loadedFolders: [SQLFavoriteFolder]?
    @State private var originalFolder: SQLFavoriteFolder?

    enum FocusField { case name, keyword }
    @FocusState private var focusedField: FocusField?

    private var isEditing: Bool { favorite != nil }
    private var effectiveFolders: [SQLFavoriteFolder] { loadedFolders ?? (folders.isEmpty ? nil : folders) ?? [] }
    private var scopeConnectionId: UUID? { isGlobal ? nil : connectionId }

    /// The folders this query is allowed to go in, which are the ones no narrower than the scope
    /// chosen above. Offering the rest is what let a global query be saved into a folder belonging
    /// to one connection, where no other connection could draw it.
    ///
    /// The folder the query arrived in stays on the list while it is still the selection, so
    /// opening a query saved before that rule existed and pressing Save never moves it. Once the
    /// scope changes and the selection clears, it goes, and cannot be chosen again.
    private var selectableFolders: [SQLFavoriteFolder] {
        var result = effectiveFolders.filter {
            SQLFavoriteScopeRule.folder($0.connectionId, canHold: scopeConnectionId)
        }
        if let originalFolder,
           originalFolder.id == selectedFolderId,
           !result.contains(where: { $0.id == originalFolder.id }) {
            result.append(originalFolder)
        }
        return result
    }

    private var hidesFoldersForScope: Bool {
        effectiveFolders.contains { !SQLFavoriteScopeRule.folder($0.connectionId, canHold: scopeConnectionId) }
    }
    private var isValid: Bool {
        SQLFavoriteEditValidation.canSave(
            isNameBlank: !name.contains { !$0.isWhitespace },
            isQueryBlank: !query.contains { !$0.isWhitespace },
            keywordValidation: keywordField.validation
        )
    }

    private static let maxQuerySize = 500_000

    /// Seeded here rather than from `onAppear`, the way `FilterSettingsPopover` seeds its settings.
    ///
    /// Populating in `onAppear` makes the scope of the record being edited a *change* to `isGlobal`,
    /// and SwiftUI runs `onChange` for it after the view has already taken the folder. So opening a
    /// global query that sits in a folder belonging to this connection cleared the folder before the
    /// user touched anything, and Save moved it to the root.
    init(
        connectionId: UUID,
        favorite: SQLFavorite? = nil,
        initialQuery: String? = nil,
        folderId: UUID? = nil,
        folders: [SQLFavoriteFolder] = []
    ) {
        self.connectionId = connectionId
        self.favorite = favorite
        self.initialQuery = initialQuery
        self.folderId = folderId
        self.folders = folders

        let seededQuery = favorite?.query ?? initialQuery ?? ""
        _name = State(initialValue: favorite?.name ?? Self.autoName(for: seededQuery))
        _query = State(initialValue: seededQuery)
        _isGlobal = State(initialValue: favorite.map { $0.connectionId == nil } ?? false)
        _selectedFolderId = State(initialValue: favorite?.folderId ?? folderId)
    }

    private static func autoName(for query: String) -> String {
        query.isEmpty ? "" : SQLFavorite.autoName(from: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow

            Divider()

            Form {
                identitySection
                querySection
                optionsSection
            }
            .formStyle(.grouped)

            Divider()

            buttonBar
        }
        .frame(width: 560, height: 580)
        .onAppear {
            populateKeyword()
            focusedField = .name
            Task {
                if folders.isEmpty {
                    loadedFolders = await SQLFavoriteManager.shared.fetchFolders(connectionId: connectionId)
                }
                await loadOriginalFolder()
            }
        }
    }

    private var titleRow: some View {
        HStack {
            Text(isEditing ? String(localized: "Edit Favorite") : String(localized: "New Favorite"))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var identitySection: some View {
        Section {
            TextField("Name", text: $name)
                .focused($focusedField, equals: .name)

            if !selectableFolders.isEmpty {
                Picker("Folder", selection: $selectedFolderId) {
                    Text(String(localized: "None")).tag(nil as UUID?)
                    ForEach(selectableFolders) { folder in
                        Text(folder.name).tag(folder.id as UUID?)
                    }
                }

                if isGlobal && hidesFoldersForScope {
                    Text("Only folders available in all connections can hold a global query.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var querySection: some View {
        Section {
            TextEditor(text: $query)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .accessibilityLabel(String(localized: "Query"))
        } header: {
            Text("Query")
        } footer: {
            Text(String(
                format: String(localized: "Type %@ in the query to set where the cursor lands after keyword expansion."),
                SQLSnippetMarker.token
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        Section {
            TextField("Keyword", text: $keywordField.keyword)
                .focused($focusedField, equals: .keyword)
                .onChange(of: keywordField.keyword) { _ in
                    revalidateKeyword()
                }

            if let message = keywordField.validation.displayText {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(keywordField.validation.isWarning ? Color.orange : Color.red)
            }

            Toggle(isOn: $isGlobal) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global")
                    Text(String(localized: "Available in all connections"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .onChange(of: isGlobal) { _ in
                revalidateKeyword()
                resolveFolderSelection()
            }
        }
    }

    private var buttonBar: some View {
        HStack {
            Spacer()

            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(isEditing ? String(localized: "Save") : String(localized: "Add")) {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Everything else is seeded in `init`. The keyword field is an observable object of its own, so
    /// it has nothing to trigger and can be filled once the view is on screen.
    private func populateKeyword() {
        keywordField.keyword = favorite?.keyword ?? ""
    }

    /// The folder the query is in, read without a scope filter.
    ///
    /// `fetchFolders(connectionId:)` answers what this connection can see, and a query saved before
    /// the containment rule can name a folder belonging to another connection. Without this the
    /// Picker would have no row matching its own selection, show nothing, and save that nothing
    /// over a placement the owning connection still draws.
    private func loadOriginalFolder() async {
        guard let folderId = selectedFolderId else { return }
        if let known = effectiveFolders.first(where: { $0.id == folderId }) {
            originalFolder = known
            return
        }
        originalFolder = await SQLFavoriteManager.shared.fetchFolder(id: folderId)
    }

    private func resolveFolderSelection() {
        guard let folderId = selectedFolderId else { return }
        let known = effectiveFolders.first(where: { $0.id == folderId }) ?? originalFolder
        guard let known, known.id == folderId else { return }
        guard !SQLFavoriteScopeRule.folder(known.connectionId, canHold: scopeConnectionId) else { return }
        selectedFolderId = nil
    }

    private func revalidateKeyword() {
        Task {
            await keywordField.validate(
                connectionId: isGlobal ? nil : connectionId,
                excludingFavoriteId: favorite?.id
            )
        }
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedKeyword = keywordField.trimmedKeyword
        let trimmedQuery: String
        if (query as NSString).length > Self.maxQuerySize {
            trimmedQuery = String(query.prefix(Self.maxQuerySize))
        } else {
            trimmedQuery = query
        }

        let scopeConnectionId = isGlobal ? nil : connectionId
        let keywordValue = trimmedKeyword.isEmpty ? nil : trimmedKeyword

        Task { @MainActor in
            let success: Bool
            if let existing = favorite {
                var updated = existing
                updated.name = trimmedName
                updated.query = trimmedQuery
                updated.keyword = keywordValue
                updated.folderId = selectedFolderId
                updated.connectionId = scopeConnectionId
                updated.updatedAt = Date()
                success = await SQLFavoriteManager.shared.updateFavorite(updated)
            } else {
                let newFavorite = SQLFavorite(
                    name: trimmedName,
                    query: trimmedQuery,
                    keyword: keywordValue,
                    folderId: selectedFolderId,
                    connectionId: scopeConnectionId
                )
                success = await SQLFavoriteManager.shared.addFavorite(newFavorite)
            }
            if success {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}
