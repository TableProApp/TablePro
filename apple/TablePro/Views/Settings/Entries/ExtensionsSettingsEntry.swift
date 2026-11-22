import SwiftUI

internal struct ExtensionsSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        InstalledPluginsView(registryClient: context.registryClient)
    }
}

internal struct ExtensionsSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        SettingsPagePlaceholder(title: context.navigation.title(for: route))
    }
}

internal struct ExtensionsStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
