import SwiftUI

internal struct AppearanceSettingsView: View {
    @Binding internal var settings: AppearanceSettings
    @Binding internal var appearanceMode: AppAppearanceMode

    internal var body: some View {
        Form {
            AppearanceChoicesView(settings: $settings, appearanceMode: $appearanceMode) {
                SettingsDrillRow(route: SettingsRoute.page(.manageThemes), title: SettingsPage.manageThemes.title)
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-appearance")
    }
}

#Preview {
    AppearanceSettingsView(settings: .constant(.default), appearanceMode: .constant(.auto))
        .frame(width: 520, height: 480)
}
