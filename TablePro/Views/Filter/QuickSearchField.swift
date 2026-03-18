//
//  QuickSearchField.swift
//  TablePro
//
//  Quick search field component for filtering across all columns.
//  Extracted from FilterPanelView for better maintainability.
//

import SwiftUI

/// Quick search field for filtering across all columns
struct QuickSearchField: View {
    @Binding var searchText: String
    @Binding var shouldFocus: Bool
    let onSubmit: () -> Void
    let onClear: () -> Void

    /// Local text state avoids firing FilterStateManager.objectWillChange on every keystroke.
    /// Only syncs to the @Published binding on submit or clear.
    @State private var localText: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                .foregroundStyle(.secondary)

            TextField("Quick search across all columns...", text: $localText)
                .textFieldStyle(.plain)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                .focused($isTextFieldFocused)
                .onSubmit {
                    if !localText.isEmpty {
                        searchText = localText
                        onSubmit()
                    }
                }

            if !localText.isEmpty {
                Button(action: {
                    localText = ""
                    searchText = ""
                    onClear()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.small))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Clear search"))
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { localText = searchText }
        .onChange(of: searchText) { _, newValue in
            // Sync from parent (e.g., tab switch restore)
            if localText != newValue { localText = newValue }
        }
        .onChange(of: shouldFocus) { _, newValue in
            if newValue {
                isTextFieldFocused = true
                shouldFocus = false
            }
        }
    }
}
