import SwiftUI

internal struct GeneralSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var general: SettingsSlice<GeneralSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._general = ObservedObject(wrappedValue: context.settings.generalSlice)
    }

    internal var body: some View {
        let settings = context.settings
        GeneralSettingsView(settings: $general.value, onResetAll: { settings.resetToDefaults() })
    }
}

internal struct GeneralSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.softwareUpdate):
            Form { SoftwareUpdateSection(updater: SoftwareUpdater.shared, updates: .shared) }
                .formStyle(.grouped)
        case .page(.commandLineTool):
            Form { CommandLineToolSection() }
                .formStyle(.grouped)
        default:
            SettingsPagePlaceholder(title: context.navigation.title(for: route))
        }
    }
}

internal struct GeneralStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
