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
    @State private var keyword: String = ""
    @State private var isGlobal: Bool = false
    @State private var selectedFolderId: UUID?
    @State private var keywordError: String?
    @State private var isKeywordWarning = false
    @State private var isSaving = false
    @State private var validationId = 0
    @State private var loadedFolders: [SQLFavoriteFolder]?

    enum FocusField { case name, keyword }
    @FocusState private var focusedField: FocusField?

    private var isEditing: Bool { favorite != nil }
    private var effectiveFolders: [SQLFavoriteFolder] { loadedFolders ?? (folders.isEmpty ? nil : folders) ?? [] }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !query.trimmingCharacters(in: .whitespaces).isEmpty &&
            (keywordError == nil || isKeywordWarning)
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
        VStack(spacing: 16) {
            Text(isEditing ? String(localized: "Edit Favorite") : String(localized: "New Favorite"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Form {
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

                LabeledContent("Query") {
                    TextEditor(text: $query)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 160)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }

                TextField("Keyword", text: $keyword)
                    .focused($focusedField, equals: .keyword)
                    .onChange(of: keyword) { _, newValue in
                        validateKeyword(newValue)
                    }

                if let error = keywordError {
                    LabeledContent {} label: {
                        Text(error)
                            .foregroundStyle(isKeywordWarning ? .orange : .red)
                            .font(.callout)
                    }
                }

                Toggle("Global", isOn: $isGlobal)
                    .help(String(localized: "When enabled, this favorite is visible in all connections"))
                    .onChange(of: isGlobal) {
                        validateKeyword(keyword)
                    }
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Add") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let fav = favorite {
                name = fav.name
                query = fav.query
                keyword = fav.keyword ?? ""
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
            focusedField = .name
            if folders.isEmpty {
                Task {
                    loadedFolders = await SQLFavoriteManager.shared.fetchFolders(connectionId: connectionId)
                }
            }
        }
    }

    // MARK: - Validation

    private func validateKeyword(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            keywordError = nil
            return
        }
        if trimmed.contains(" ") {
            isKeywordWarning = false
            keywordError = String(localized: "Keyword cannot contain spaces")
            return
        }
        validationId += 1
        let currentId = validationId
        Task { @MainActor in
            let scopeConnectionId = isGlobal ? nil : connectionId
            let available = await SQLFavoriteManager.shared.isKeywordAvailable(
                trimmed,
                connectionId: scopeConnectionId,
                excludingFavoriteId: favorite?.id
            )
            guard currentId == validationId else { return }
            if !available {
                isKeywordWarning = false
                keywordError = String(localized: "This keyword is already in use")
            } else {
                let sqlKeywords: Set<String> = [
                    "select", "from", "where", "insert", "update", "delete",
                    "create", "drop", "alter", "join", "on", "and", "or",
                    "not", "in", "like", "between", "order", "group", "having",
                    "limit", "set", "values", "into", "as", "is", "null",
                    "true", "false", "case", "when", "then", "else", "end"
                ]
                if sqlKeywords.contains(trimmed.lowercased()) {
                    isKeywordWarning = true
                    keywordError = String(
                        format: String(localized: "Shadows the SQL keyword '%@'"),
                        trimmed.uppercased()
                    )
                } else {
                    isKeywordWarning = false
                    keywordError = nil
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespaces)
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
