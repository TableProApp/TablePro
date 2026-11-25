import SwiftUI
import TableProTheme

// The appearance mode and the two theme pickers, as Form sections.
internal struct AppearanceChoicesView<ThemeRows: View>: View {
    @Binding internal var settings: AppearanceSettings
    @Binding internal var appearanceMode: AppAppearanceMode
    private let themeRows: ThemeRows

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
                ForEach(AppAppearanceMode.choices, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("Appearance")
                Text("Controls, sidebars and Settings follow this. Applies to this Mac.")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance-mode-picker")
        }

        Section("Themes") {
            ThemeSlotPicker(slot: .light, settings: $settings)
            ThemeSlotPicker(slot: .dark, settings: $settings)
            themeRows
        }
    }
}

// The setup guide's appearance tiles show the same three, in this order.
internal extension AppAppearanceMode {
    static let choices: [AppAppearanceMode] = [.auto, .light, .dark]

    var title: String {
        switch self {
        case .auto: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}
