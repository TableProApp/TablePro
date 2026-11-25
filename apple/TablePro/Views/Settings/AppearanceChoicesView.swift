import SwiftUI
import TableProTheme

// The appearance mode and the two theme pickers, as Form sections; Settings and the setup guide both show them.
internal struct AppearanceChoicesView<ThemeRows: View>: View {
    @Binding internal var settings: AppearanceSettings
    @Binding internal var appearanceMode: AppAppearanceMode
    private let themeRows: ThemeRows

    @ObservedObject private var catalog = ThemeCatalog.shared

    private static var modes: [AppAppearanceMode] { [.auto, .light, .dark] }

    internal init(
        settings: Binding<AppearanceSettings>,
        appearanceMode: Binding<AppAppearanceMode>,
        @ViewBuilder themeRows: () -> ThemeRows
    ) {
        _settings = settings
        _appearanceMode = appearanceMode
        self.themeRows = themeRows()
    }

    internal var body: some View {
        Section {
            Picker(selection: $appearanceMode) {
                ForEach(Self.modes, id: \.self) { mode in
                    Text(Self.title(for: mode)).tag(mode)
                }
            } label: {
                Text("Appearance")
                Text("Controls, sidebars and Settings follow this. Applies to this Mac.")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance-mode-picker")
        }

        Section("Themes") {
            themePicker(ThemeSlotChoice(slot: .light, savedId: settings.preferredLightThemeId, themes: catalog.themes))
            themePicker(ThemeSlotChoice(slot: .dark, savedId: settings.preferredDarkThemeId, themes: catalog.themes))
            themeRows
        }
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
        .pickerStyle(.menu)
        .accessibilityIdentifier("appearance-\(choice.slot.rawValue)-theme")
    }

    // Shows the theme in use, but only a pick writes: a saved id this Mac cannot resolve stays saved
    // for the Mac that has the theme.
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

internal extension AppearanceChoicesView where ThemeRows == EmptyView {
    init(settings: Binding<AppearanceSettings>, appearanceMode: Binding<AppAppearanceMode>) {
        self.init(settings: settings, appearanceMode: appearanceMode) { EmptyView() }
    }
}
