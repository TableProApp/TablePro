import SwiftUI

internal struct SidebarTabsSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var general: SettingsSlice<GeneralSettings>
    @ObservedObject private var tabs: SettingsSlice<TabSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._general = ObservedObject(wrappedValue: context.settings.generalSlice)
        self._tabs = ObservedObject(wrappedValue: context.settings.tabsSlice)
    }

    internal var body: some View {
        SidebarTabsSettingsView(settings: $general.value, tabSettings: $tabs.value)
    }
}

// No SettingsPage has Sidebar & Tabs as its parent, so nothing reaches this.
internal struct SidebarTabsSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        EmptyView()
    }
}

internal struct SidebarTabsStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
