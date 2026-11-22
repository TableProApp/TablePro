import SwiftUI

internal struct SyncSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var sync: SettingsSlice<SyncSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._sync = ObservedObject(wrappedValue: context.settings.syncSlice)
    }

    internal var body: some View {
        SyncSettingsView(settings: $sync.value)
    }
}

// iCloud Sync has no pages since What Syncs moved inline, so nothing reaches this.
internal struct SyncSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        EmptyView()
    }
}

internal struct SyncStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
