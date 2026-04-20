//
//  AppearanceSettingsView.swift
//  TablePro
//
//  Settings for theme browsing, customization, and accent color.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Binding var settings: AppearanceSettings

    /// Computed binding that reads/writes the correct preferred theme slot.
    /// On read: returns the theme for the current effective appearance.
    /// On write: uses the selected theme's appearance metadata to determine the correct slot,
    /// and switches the appearance mode so the user sees the change immediately.
    private var effectiveThemeIdBinding: Binding<String> {
        Binding(
            get: {
                ThemeEngine.shared.effectiveAppearance == .dark
                    ? settings.preferredDarkThemeId
                    : settings.preferredLightThemeId
            },
            set: { newId in
                guard let theme = ThemeEngine.shared.availableThemes
                    .first(where: { $0.id == newId }) else { return }

                // Assign to the correct slot based on the theme's appearance and
                // switch mode to match so the user sees the change immediately.
                // Mutate a local copy so didSet fires only once.
                var updated = settings
                switch theme.appearance {
                case .dark:
                    updated.preferredDarkThemeId = newId
                    updated.appearanceMode = .dark
                case .light:
                    updated.preferredLightThemeId = newId
                    updated.appearanceMode = .light
                case .auto:
                    updated.appearanceMode = .auto
                    if ThemeEngine.shared.effectiveAppearance == .dark {
                        updated.preferredDarkThemeId = newId
                    } else {
                        updated.preferredLightThemeId = newId
                    }
                }
                settings = updated
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Appearance")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("", selection: $settings.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            HSplitView {
                ThemeListView(selectedThemeId: effectiveThemeIdBinding)
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 250)

                ThemeEditorView(selectedThemeId: effectiveThemeIdBinding)
                    .frame(minWidth: 400)
            }
        }
    }
}

#Preview {
    AppearanceSettingsView(settings: .constant(.default))
        .frame(width: 720, height: 500)
}
