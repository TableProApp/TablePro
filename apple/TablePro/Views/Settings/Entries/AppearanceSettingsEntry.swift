import SwiftUI

internal struct AppearanceSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var appearance: SettingsSlice<AppearanceSettings>
    @ObservedObject private var appearanceMode: SettingsSlice<AppAppearanceMode>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._appearance = ObservedObject(wrappedValue: context.settings.appearanceSlice)
        self._appearanceMode = ObservedObject(wrappedValue: context.settings.appearanceModeSlice)
    }

    internal var body: some View {
        AppearanceSettingsView(settings: $appearance.value, appearanceMode: $appearanceMode.value)
    }
}

internal struct AppearanceSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.manageThemes):
            ThemeLibrarySection(model: context.models.themeLibrary)
        default:
            EmptyView()
        }
    }
}

internal struct AppearanceStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
            .onAppear {
                Self.routeOffPageAlerts(of: context.models.themeLibrary, to: context)
            }
    }

    // A theme undo from the root page or another pane fails with no Manage Themes page to show it.
    internal static func routeOffPageAlerts(of model: ThemeLibraryModel, to context: SettingsPaneContext) {
        model.presentOffPage = { [weak context] alert in
            guard let context, context.path.routes.last != .page(.manageThemes) else { return false }
            context.presentError(title: alert.title, message: alert.message)
            return true
        }
    }
}
