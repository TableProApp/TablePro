import SwiftUI

protocol SettingsDrillIdentifying {
    var settingsDrillIdentifier: String? { get }
}

struct SettingsDrillRow<Route: Hashable>: View {
    private let route: Route
    private let title: Text
    private let value: String?
    private let identifier: String?

    init(route: Route, title: LocalizedStringKey, value: String? = nil, identifier: String? = nil) {
        self.init(route: route, titleText: Text(title), value: value, identifier: identifier)
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(route: Route, title: Title, value: String? = nil, identifier: String? = nil) {
        self.init(route: route, titleText: Text(title), value: value, identifier: identifier)
    }

    private init(route: Route, titleText: Text, value: String?, identifier: String?) {
        self.route = route
        self.title = titleText
        self.value = value
        // Route stays any Hashable for NavigationLink, so the page id comes from a route that adopts the protocol.
        self.identifier = identifier ?? (route as? any SettingsDrillIdentifying)?.settingsDrillIdentifier
    }

    var body: some View {
        NavigationLink(value: route) {
            LabeledContent {
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                }
            } label: {
                title
            }
        }
        .accessibilityIdentifier(identifier ?? "")
    }
}
