//
//  AppearanceSettingsView.swift
//  TablePro
//
//  Settings for theme browsing, customization, and accent color.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Binding var settings: AppearanceSettings

    /// Computed binding that reads/writes the correct preferred theme slot
    /// based on the current effective appearance.
    private var effectiveThemeIdBinding: Binding<String> {
        Binding(
            get: {
                ThemeEngine.shared.effectiveAppearance == .dark
                    ? settings.preferredDarkThemeId
                    : settings.preferredLightThemeId
            },
            set: { newId in
                if ThemeEngine.shared.effectiveAppearance == .dark {
                    settings.preferredDarkThemeId = newId
                } else {
                    settings.preferredLightThemeId = newId
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Appearance")
                    .font(.system(size: 12))
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
