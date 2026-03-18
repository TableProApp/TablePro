//
//  AppearanceSettingsView.swift
//  TablePro
//
//  Settings for theme browsing, customization, and accent color.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Binding var settings: AppearanceSettings

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
                ThemeListView(selectedThemeId: $settings.activeThemeId)
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 250)

                ThemeEditorView(selectedThemeId: $settings.activeThemeId)
                    .frame(minWidth: 400)
            }
        }
    }
}

#Preview {
    AppearanceSettingsView(settings: .constant(.default))
        .frame(width: 720, height: 500)
}
