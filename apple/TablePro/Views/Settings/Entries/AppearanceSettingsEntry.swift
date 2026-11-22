import SwiftUI

internal struct AppearanceSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var appearance: SettingsSlice<AppearanceSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._appearance = ObservedObject(wrappedValue: context.settings.appearanceSlice)
    }

    internal var body: some View {
        AppearanceSettingsView(settings: $appearance.value)
    }
}

internal struct AppearanceSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.manageThemes):
            // Not in a Form: a List inside a grouped Form does not scroll on macOS.
            ThemeLibrarySection()
        default:
            SettingsPagePlaceholder(title: context.navigation.title(for: route))
        }
    }
}

internal struct AppearanceStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
