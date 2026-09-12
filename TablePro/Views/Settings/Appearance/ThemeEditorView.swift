import os
import SwiftUI

/// Edits the theme the slot holds, not the theme in effect. Reading `activeTheme` here meant that
/// with the Mac in light mode and the pane set to Editing: Dark, every edit, duplicate and delete
/// landed on the light theme, and the dark slot was then pointed at it.
internal struct ThemeEditorView: View {
    @Binding internal var selectedThemeId: String
    internal let slotAppearance: ThemeAppearance

    @State private var errorMessage: String?
    @State private var showError = false

    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeEditorView")

    private var catalog: ThemeCatalog { ThemeCatalog.shared }

    private var theme: ThemeDefinition {
        catalog.theme(id: selectedThemeId) ?? BuiltInThemes.default(for: slotAppearance)
    }

    internal var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if theme.isEditable {
                ThemeEditorColorsSection(theme: theme)
            } else {
                duplicatePrompt
            }
        }
        .alert(String(localized: "Error"), isPresented: $showError) {
            Button(String(localized: "OK")) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(theme.name)
                .font(.title3.weight(.semibold))

            Text(theme.author.isEmpty ? String(localized: "Custom theme") : theme.author)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var duplicatePrompt: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(theme.isBuiltIn
                ? String(localized: "This is a built-in theme.")
                : String(localized: "This is a registry theme."))
                .font(.body)
                .foregroundStyle(.secondary)

            Text("Duplicate it to change its colors.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Button("Duplicate Theme") {
                duplicateAndSelect()
            }
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func duplicateAndSelect() {
        var copy = theme
        copy.id = ThemeIdentifier.generated()
        copy.name = String(format: String(localized: "%@ (Copy)"), theme.name)

        do {
            try catalog.save(copy)
            selectedThemeId = copy.id
        } catch {
            Self.logger.error("Could not duplicate theme: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
