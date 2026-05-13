//
//  LinkedFavoriteMetadataDialog.swift
//  TablePro
//

import SwiftUI

internal struct LinkedFavoriteMetadataDialog: View {
    let favorite: LinkedSQLFavorite
    let connectionId: UUID
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var keyword: String = ""
    @State private var fileDescription: String = ""
    @State private var keywordError: String?
    @State private var isKeywordWarning = false
    @State private var validationId = 0
    @State private var isSaving = false
    @State private var saveError: String?

    @FocusState private var nameFocused: Bool

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespaces)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (keywordError == nil || isKeywordWarning)
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Edit Metadata"))
                    .font(.headline)
                Text(favorite.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Form {
                TextField(String(localized: "Name"), text: $name)
                    .focused($nameFocused)
                TextField(String(localized: "Keyword"), text: $keyword)
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
                TextField(String(localized: "Description"), text: $fileDescription, axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.columns)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isSaving)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            name = favorite.name
            keyword = favorite.keyword ?? ""
            fileDescription = favorite.fileDescription ?? ""
            nameFocused = true
        }
    }

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
            let available = await SQLFavoriteManager.shared.isKeywordAvailable(
                trimmed,
                connectionId: connectionId,
                excludingFavoriteId: nil
            )
            guard currentId == validationId else { return }
            if !available {
                isKeywordWarning = false
                keywordError = String(localized: "This keyword is already in use")
                return
            }
            let sqlKeywords: Set<String> = [
                "select", "from", "where", "insert", "update", "delete",
                "create", "drop", "alter", "join", "on", "and", "or",
                "not", "in", "like", "between", "order", "group", "having",
                "limit", "set", "values", "into", "as", "is", "null",
                "true", "false", "case", "when", "then", "else", "end"
            ]
            if sqlKeywords.contains(trimmed.lowercased()) {
                isKeywordWarning = true
                keywordError = String(format: String(localized: "Shadows the SQL keyword '%@'"), trimmed.uppercased())
            } else {
                isKeywordWarning = false
                keywordError = nil
            }
        }
    }

    private func save() {
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = fileDescription.trimmingCharacters(in: .whitespaces)

        let metadata = SQLFrontmatter.Metadata(
            name: trimmedName.isEmpty ? nil : trimmedName,
            keyword: trimmedKeyword.isEmpty ? nil : trimmedKeyword,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription
        )

        Task { @MainActor in
            do {
                try LinkedSQLFavoriteWriter.writeMetadata(metadata, to: favorite.fileURL)
                SQLFolderWatcher.shared.reload()
                onSaved()
                dismiss()
            } catch LinkedSQLFavoriteWriter.WriteError.encodingMismatch(let encoding) {
                isSaving = false
                saveError = String(format: String(localized: "File encoding (%@) cannot represent these characters. Convert the file to UTF-8 to save."), encoding.displayName)
            } catch LinkedSQLFavoriteWriter.WriteError.readFailed {
                isSaving = false
                saveError = String(localized: "Could not read the file. It may have been deleted or moved.")
            } catch {
                isSaving = false
                saveError = String(localized: "Could not write to file. Check that the file is writable.")
            }
        }
    }
}
