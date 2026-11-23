import SwiftUI

internal struct ProfilesSettingsEntry: View {
    internal let context: SettingsPaneContext
    @ObservedObject private var visit: SettingsPaneVisit
    @StateObject private var model = ProfilesSettingsModel()

    internal init(context: SettingsPaneContext) {
        self.context = context
        self._visit = ObservedObject(wrappedValue: context.visit)
    }

    internal var body: some View {
        ProfilesSettingsView(model: model, presentError: context.presentError)
            .task(id: visit.count) { model.refresh() }
    }
}

// Profiles owns no SettingsPage: its editors are sheets, so no route reaches this.
internal struct ProfilesSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext

    internal var body: some View {
        EmptyView()
    }
}

internal struct ProfilesStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
