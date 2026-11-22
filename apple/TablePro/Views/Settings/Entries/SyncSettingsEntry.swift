import SwiftUI

internal struct SyncSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        SyncSettingsView()
    }
}

internal struct SyncSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        SettingsPagePlaceholder(title: context.navigation.title(for: route))
    }
}

internal struct SyncStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
