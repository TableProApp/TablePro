import SwiftUI

internal struct AppearanceSettingsView: View {
    @Binding internal var settings: AppearanceSettings

    @ObservedObject private var catalog = ThemeCatalog.shared

    private static let modes: [AppAppearanceMode] = [.auto, .light, .dark]

    internal var body: some View {
        Form {
            Section {
                Picker(String(localized: "Appearance"), selection: $settings.appearanceMode) {
                    ForEach(Self.modes, id: \.self) { mode in
                        Text(Self.title(for: mode)).tag(mode)
                    }
                }
                .accessibilityIdentifier("appearance-mode-picker")
            }

            Section {
                themePicker(ThemeSlotChoice(slot: .light, savedId: settings.preferredLightThemeId, themes: catalog.themes))
                themePicker(ThemeSlotChoice(slot: .dark, savedId: settings.preferredDarkThemeId, themes: catalog.themes))
            } footer: {
                Text("Themes color the editor, the data grid, other content views and the window background. Controls, sidebars and Settings follow the system appearance.")
            }

            CustomThemesSection(settings: $settings)
        }
        .formStyle(.grouped)
    }

    private static func title(for mode: AppAppearanceMode) -> String {
        switch mode {
        case .auto: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    private func themePicker(_ choice: ThemeSlotChoice) -> some View {
        Picker(selection: selectionBinding(for: choice)) {
            ForEach(choice.builtIn) { theme in
                Text(theme.name).tag(theme.id)
            }
            if !choice.custom.isEmpty {
                Divider()
                ForEach(choice.custom) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
        } label: {
            Text(choice.title)
            if let note = choice.noteMessage {
                Text(note)
                    .accessibilityIdentifier("appearance-\(choice.slot.rawValue)-theme-note")
            }
        }
        .accessibilityIdentifier("appearance-\(choice.slot.rawValue)-theme")
    }

    /// The popup shows the theme in use, but only a pick writes the setting: a saved id this Mac
    /// cannot resolve stays saved for the Mac that has the theme.
    private func selectionBinding(for choice: ThemeSlotChoice) -> Binding<String> {
        Binding(
            get: { choice.selectedId },
            set: { id in
                var updated = settings
                switch choice.slot {
                case .light: updated.preferredLightThemeId = id
                case .dark: updated.preferredDarkThemeId = id
                }
                settings = updated
            }
        )
    }
}

#Preview {
    AppearanceSettingsView(settings: .constant(.default))
        .frame(width: 720, height: 560)
}
