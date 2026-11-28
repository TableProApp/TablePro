import SwiftUI

protocol SettingsDrillIdentifying {
    var settingsDrillIdentifier: String? { get }
}

struct SettingsDrillRow<Route: Hashable>: View {
    private let route: Route
    private let title: Text
    private let subtitle: Text?
    private let value: String?
    private let identifier: String?

    init(
        route: Route,
        title: LocalizedStringKey,
        value: String? = nil,
        subtitle: LocalizedStringKey? = nil,
        identifier: String? = nil
    ) {
        self.init(route: route, titleText: Text(title), value: value, subtitle: subtitle.map { Text($0) }, identifier: identifier)
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(
        route: Route,
        title: Title,
        value: String? = nil,
        subtitle: LocalizedStringKey? = nil,
        identifier: String? = nil
    ) {
        self.init(route: route, titleText: Text(title), value: value, subtitle: subtitle.map { Text($0) }, identifier: identifier)
    }

    // A record listed under its own name, with a detail already localized: a team and its role and seat.
    init(route: Route, name: String, detail: String?, identifier: String? = nil) {
        self.init(
            route: route, titleText: Text(verbatim: name), value: nil, subtitle: detail.map { Text(verbatim: $0) }, identifier: identifier
        )
    }

    private init(route: Route, titleText: Text, value: String?, subtitle: Text?, identifier: String?) {
        self.route = route
        self.title = titleText
        self.subtitle = subtitle
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
                if let subtitle {
                    subtitle
                }
            }
        }
        .accessibilityIdentifier(identifier ?? "")
    }
}
