import SwiftUI

internal struct AccountSettingsEntry: View {
    internal let context: SettingsPaneContext

    internal var body: some View {
        AccountSettingsView(model: context.models.account)
    }
}

internal struct AccountSettingsPageEntry: View {
    internal let route: SettingsRoute
    internal let context: SettingsPaneContext
    @ObservedObject private var account: AccountSettingsModel

    internal init(route: SettingsRoute, context: SettingsPaneContext) {
        self.route = route
        self.context = context
        self._account = ObservedObject(wrappedValue: context.models.account)
    }

    internal var body: some View {
        switch route {
        case .page(.accountFeatures):
            Form {
                AccountFeaturesSection(access: account.access, offersPurchase: account.content.identity == .signedOut)
            }
            .formStyle(.grouped)
        default:
            SettingsPagePlaceholder(title: context.navigation.title(for: route))
        }
    }
}

internal struct AccountStackPresentations: ViewModifier {
    internal let context: SettingsPaneContext

    internal func body(content: Content) -> some View {
        content
    }
}
