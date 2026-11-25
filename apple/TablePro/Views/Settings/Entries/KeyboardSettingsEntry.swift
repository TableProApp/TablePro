import SwiftUI

internal struct KeyboardSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal init(context: SettingsPaneContext) {
        self.context = context
    }

    // Never nil: SettingsPaneContext.filtersItsList(.keyboard) is true.
    internal var body: some View {
        if let filter = context.filter {
            KeyboardSettingsView(keyboard: context.settings.keyboardSlice, filter: filter)
        }
    }
}

// Keyboard has no pages, and the navigation model never pushes another pane's route here.
internal struct KeyboardSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        EmptyView()
    }
}

internal struct KeyboardStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
