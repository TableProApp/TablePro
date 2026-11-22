import SwiftUI

internal struct ConnectionsSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var general: SettingsSlice<GeneralSettings>

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._general = ObservedObject(wrappedValue: context.settings.generalSlice)
    }

    internal var body: some View {
        ConnectionsSettingsView(settings: $general.value)
    }
}

internal struct ConnectionsSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        switch route {
        case .page(.linkedFolders):
            LinkedFoldersPage()
        case .page(.trustedLinks):
            TrustedLinksPage()
        default:
            // The model never pushes a route of another pane onto this stack.
            EmptyView()
        }
    }
}

// The root's counts and both pages read one pair of models, alive as long as the pane host.
internal struct ConnectionsStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext
    @ObservedObject private var visit: SettingsPaneVisit
    @StateObject private var linkedFolders = LinkedFoldersModel()
    @StateObject private var trustedLinks = TrustedLinksModel()

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._visit = ObservedObject(wrappedValue: context.visit)
    }

    internal func body(content: Content) -> some View {
        content
            .environmentObject(linkedFolders)
            .environmentObject(trustedLinks)
            .task(id: visit.count) {
                linkedFolders.reload()
                trustedLinks.refresh()
            }
    }
}
