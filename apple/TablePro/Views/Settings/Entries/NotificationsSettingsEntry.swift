import SwiftUI

internal struct NotificationsSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var notifications: SettingsSlice<NotificationSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._notifications = ObservedObject(wrappedValue: context.settings.notificationsSlice)
    }

    internal var body: some View {
        NotificationsSettingsView(settings: $notifications.value)
    }
}

internal struct NotificationsSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        SettingsPagePlaceholder(title: context.navigation.title(for: route))
    }
}

internal struct NotificationsStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
