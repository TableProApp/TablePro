import SwiftUI

internal struct ConnectionsSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var general: SettingsSlice<GeneralSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._general = ObservedObject(wrappedValue: context.settings.generalSlice)
    }

    internal var body: some View {
        ConnectionsSettingsView(settings: $general.value)
    }
}

internal struct ConnectionsSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.linkedFolders):
            Form { LinkedFoldersSection() }
                .formStyle(.grouped)
        case .page(.trustedLinks):
            Form { TrustedExternalConnectionsSection() }
                .formStyle(.grouped)
        default:
            SettingsPagePlaceholder(title: context.navigation.title(for: route))
        }
    }
}

internal struct ConnectionsStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
