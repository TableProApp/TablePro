import SwiftUI

internal struct AISettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var ai: SettingsSlice<AISettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._ai = ObservedObject(wrappedValue: context.settings.aiSlice)
    }

    internal var body: some View {
        AISettingsView(settings: $ai.value)
    }
}

internal struct AISettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.slashCommands):
            Form { CustomSlashCommandsSection(storage: CustomSlashCommandStorage.shared) }
                .formStyle(.grouped)
        default:
            SettingsPagePlaceholder(title: context.navigation.title(for: route))
        }
    }
}

internal struct AIStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
