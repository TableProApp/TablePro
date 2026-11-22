import SwiftUI

internal struct ProfilesSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        ProfilesSettingsView()
    }
}

internal struct ProfilesSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        SettingsPagePlaceholder(title: context.navigation.title(for: route))
    }
}

internal struct ProfilesStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
