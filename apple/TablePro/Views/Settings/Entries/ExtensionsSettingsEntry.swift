import SwiftUI

internal struct ExtensionsSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        InstalledPluginsView(context: context)
    }
}

internal struct ExtensionsSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext
    @EnvironmentObject private var model: ExtensionsPaneModel

    internal var body: some View {
        switch model.page(for: route) {
        case .plugin(let entry, let isStaged):
            PluginDetailPage(entry: entry, isStaged: isStaged, context: context)
        case .rejected(let row):
            RejectedPluginDetailPage(row: row, context: context, tracker: model.manager.installTracker)
        case .unavailable:
            UnavailableStateView(
                String(localized: "Plugin Not Available"),
                systemImage: "puzzlepiece.extension",
                description: Text("It was removed or replaced.")
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("extensions-plugin-unavailable")
        }
    }
}

// The model sits above the stack, so the root and every pushed page share one view of the plugin manager.
internal struct ExtensionsStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext
    @StateObject private var model: ExtensionsPaneModel

    internal init(context: SettingsPaneContext) {
        self.context = context
        _model = StateObject(wrappedValue: ExtensionsPaneModel(registryClient: context.registryClient))
    }

    internal func body(content: Content) -> some View {
        content
            .environmentObject(model)
    }
}
