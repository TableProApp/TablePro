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
    @State private var keywordField = SQLFavoriteKeywordField()
    @State private var fileDescription: String = ""
    @State private var isSaving = false
    @State private var saveError: String?

    @FocusState private var nameFocused: Bool

    private var isValid: Bool {
        SQLFavoriteEditValidation.canSave(
            isNameBlank: !name.contains { !$0.isWhitespace },
            keywordValidation: keywordField.validation
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow

            Divider()

            Form {
                identitySection
                keywordSection
            }
            .formStyle(.grouped)

            if let saveError {
                Divider()
                errorBanner(saveError)
            }

            Divider()

            buttonBar
        }
        .frame(width: 480, height: 400)
        .onAppear {
            name = favorite.name
            keywordField.keyword = favorite.keyword ?? ""
            fileDescription = favorite.fileDescription ?? ""
            nameFocused = true
        }
    }

    private var titleRow: some View {
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var identitySection: some View {
        Section {
            TextField(String(localized: "Name"), text: $name)
                .focused($nameFocused)
            TextField(String(localized: "Description"), text: $fileDescription, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private var keywordSection: some View {
        Section {
            TextField(String(localized: "Keyword"), text: $keywordField.keyword)
                .onChange(of: keywordField.keyword) {
                    revalidateKeyword()
                }

            if let message = keywordField.validation.displayText {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(keywordField.validation.isWarning ? Color.orange : Color.red)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var buttonBar: some View {
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
            .disabled(!isValid || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func revalidateKeyword() {
        Task {
            await keywordField.validate(connectionId: connectionId, excludingFavoriteId: nil)
        }
    }

    private func save() {
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedKeyword = keywordField.trimmedKeyword
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
