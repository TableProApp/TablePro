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

    @State private var name: String = ""
    @State private var query: String = ""
    @State private var keywordField = SQLFavoriteKeywordField()
    @State private var isGlobal: Bool = false
    @State private var selectedFolderId: UUID?
    @State private var isSaving = false
    @State private var loadedFolders: [SQLFavoriteFolder]?

    enum FocusField { case name, keyword }
    @FocusState private var focusedField: FocusField?

    private var isEditing: Bool { favorite != nil }
    private var effectiveFolders: [SQLFavoriteFolder] { loadedFolders ?? (folders.isEmpty ? nil : folders) ?? [] }
    private var isValid: Bool {
        SQLFavoriteEditValidation.canSave(
            isNameBlank: !name.contains { !$0.isWhitespace },
            isQueryBlank: !query.contains { !$0.isWhitespace },
            keywordValidation: keywordField.validation
        )
    }

    private static let maxQuerySize = 500_000

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
            populateFields()
            focusedField = .name
            if folders.isEmpty {
                Task {
                    loadedFolders = await SQLFavoriteManager.shared.fetchFolders(connectionId: connectionId)
                }
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

    private var identitySection: some View {
        Section {
            TextField("Name", text: $name)
                .focused($focusedField, equals: .name)

            if !effectiveFolders.isEmpty {
                Picker("Folder", selection: $selectedFolderId) {
                    Text(String(localized: "None")).tag(nil as UUID?)
                    ForEach(effectiveFolders) { folder in
                        Text(folder.name).tag(folder.id as UUID?)
                    }
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
                .onChange(of: keywordField.keyword) {
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
            .onChange(of: isGlobal) {
                revalidateKeyword()
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

    private func populateFields() {
        if let fav = favorite {
            name = fav.name
            query = fav.query
            keywordField.keyword = fav.keyword ?? ""
            isGlobal = fav.connectionId == nil
            selectedFolderId = fav.folderId
        } else {
            selectedFolderId = folderId
            if let q = initialQuery {
                query = q
            }
            if name.isEmpty && !query.isEmpty {
                name = SQLFavorite.autoName(from: query)
            }
        }
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
