//
//  ThemeEditorView.swift
//  TablePro
//
//  Right panel of the appearance HSplitView: theme header, accent color, and tabbed editor sections.
//

import SwiftUI

internal struct ThemeEditorView: View {
    @Binding var selectedThemeId: String

    private var engine: ThemeEngine { ThemeEngine.shared }
    private var theme: ThemeDefinition { engine.activeTheme }
    private var isEditable: Bool { theme.isEditable }

    @State private var activeTab: EditorTab = .fonts

    @State private var errorMessage: String?
    @State private var showError = false

    private enum EditorTab: String, CaseIterable {
        case fonts = "Fonts"
        case colors = "Colors"

        var localizedName: String {
            switch self {
            case .fonts: return String(localized: "Fonts")
            case .colors: return String(localized: "Colors")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(theme.name)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Picker("", selection: $activeTab) {
                ForEach(EditorTab.allCases, id: \.self) { tab in
                    Text(tab.localizedName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            tabContent
        }
        .alert(String(localized: "Error"), isPresented: $showError) {
            Button(String(localized: "OK")) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .fonts:
            ThemeEditorFontsSection(onThemeDuplicated: { newTheme in
                selectedThemeId = newTheme.id
            })
        case .colors:
            if isEditable {
                ThemeEditorColorsSection()
            } else {
                duplicatePrompt
            }
        }
    }

    private var duplicatePrompt: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)

            Text(theme.isBuiltIn
                ? String(localized: "This is a built-in theme.")
                : String(localized: "This is a registry theme."))
                .font(.body)
                .foregroundStyle(.secondary)

            Text(String(localized: "Duplicate it to customize colors."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Button(String(localized: "Duplicate Theme")) {
                duplicateAndSelect()
            }
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func duplicateAndSelect() {
        let copy = engine.duplicateTheme(theme, newName: theme.name + " (Copy)")
        do {
            try engine.saveUserTheme(copy)
            engine.activateTheme(copy)
            selectedThemeId = copy.id
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
