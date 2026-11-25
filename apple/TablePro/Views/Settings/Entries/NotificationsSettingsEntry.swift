import SwiftUI

internal struct NotificationsSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var notifications: SettingsSlice<NotificationSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._notifications = ObservedObject(wrappedValue: context.settings.notificationsSlice)
    }

    internal var body: some View {
        NotificationsSettingsView(settings: $notifications.value, visit: context.visit)
    }
}

// Notifications has no pages, and the navigation model never pushes another pane's route here.
internal struct NotificationsSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        EmptyView()
    }
}

internal struct NotificationsStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
