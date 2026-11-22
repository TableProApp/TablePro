import SwiftUI

internal struct KeyboardSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var keyboard: SettingsSlice<KeyboardSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._keyboard = ObservedObject(wrappedValue: context.settings.keyboardSlice)
    }

    internal var body: some View {
        KeyboardSettingsView(settings: $keyboard.value)
    }
}

internal struct KeyboardSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        SettingsPagePlaceholder(title: context.navigation.title(for: route))
    }
}

internal struct KeyboardStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
