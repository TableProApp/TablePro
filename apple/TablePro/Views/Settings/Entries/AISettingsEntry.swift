import SwiftUI

internal struct AISettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var ai: SettingsSlice<AISettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._ai = ObservedObject(wrappedValue: context.settings.aiSlice)
    }

    internal var body: some View {
        AISettingsView(settings: $ai.value, visit: context.visit)
    }
}

internal struct AISettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal init(route: SettingsRoute, context: SettingsPaneContext) {
        self.route = route
        self.context = context
    }

    // A route of another pane never reaches this stack.
    internal var body: some View {
        switch route {
        case .page(.slashCommands):
            SlashCommandsPage(storage: CustomSlashCommandStorage.shared)
        case .aiProvider(let id):
            AIProviderPage(providerID: id, slice: context.settings.aiSlice)
        default:
            EmptyView()
        }
    }
}

// Root and provider pages share the removal alert and the pane model, so both live on the stack.
internal struct AIStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext
    @StateObject private var paneModel = AISettingsPaneModel()

    internal init(context: SettingsPaneContext) {
        self.context = context
    }

    internal func body(content: Content) -> some View {
        content
            .environmentObject(paneModel)
            .aiProviderRemovalAlert(pending: $paneModel.pendingRemoval) { provider in
                paneModel.remove(provider, from: context.settings.aiSlice, navigation: context.navigation)
            }
    }
}
