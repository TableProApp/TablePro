//
//  AppearanceSettingsView.swift
//  TablePro
//
//  Settings for theme browsing and customization.
//

import SwiftUI

enum ThemeEditSlot: Hashable {
    case light
    case dark
}

struct AppearanceSettingsView: View {
    @Binding var settings: AppearanceSettings
    @State private var chosenSlot: ThemeEditSlot?

    /// The slot currently being edited. Defaults to the active appearance so the
    /// pane opens on the theme in use, but the user can switch to edit the other
    /// slot without changing the app's appearance mode.
    private var editSlot: ThemeEditSlot {
        chosenSlot ?? (ThemeEngine.shared.effectiveAppearance == .dark ? .dark : .light)
    }

    private var slotThemeBinding: Binding<String> {
        Binding(
            get: {
                editSlot == .dark ? settings.preferredDarkThemeId : settings.preferredLightThemeId
            },
            set: { newId in
                var updated = settings
                if editSlot == .dark {
                    updated.preferredDarkThemeId = newId
                } else {
                    updated.preferredLightThemeId = newId
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

                Text("Editing")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(get: { editSlot }, set: { chosenSlot = $0 })) {
                    Text("Light").tag(ThemeEditSlot.light)
                    Text("Dark").tag(ThemeEditSlot.dark)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            HSplitView {
                ThemeListView(selectedThemeId: slotThemeBinding)
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 250)

                ThemeEditorView(selectedThemeId: slotThemeBinding)
                    .frame(minWidth: 400)
            }
        }
    }
}

#Preview {
    AppearanceSettingsView(settings: .constant(.default))
        .frame(width: 720, height: 500)
}
