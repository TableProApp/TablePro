import SwiftUI

internal struct GeneralSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        let settings = context.settings
        GeneralSettingsView(settings: settings.generalSlice, onResetAll: { settings.resetToDefaults() })
    }
}

internal struct GeneralSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.softwareUpdate):
            SoftwareUpdatePage(updater: .shared, updates: .shared)
        case .page(.commandLineTool):
            CommandLineToolPage(visit: context.visit)
        default:
            EmptyView()
        }
    }
}

internal struct GeneralStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
