//
//  SupportLinks.swift
//  TablePro
//
//  Outbound links to the pricing page and to GitHub Sponsors, tagged with where they were clicked.
//

import Foundation

/// Where in the app an outbound support link was clicked.
///
/// Values stay inside alphanumerics, dashes and underscores, which is the character set GitHub
/// Sponsors accepts for its metadata parameters.
internal enum SupportReferrer: Equatable {
    case supportWindow
    case aboutPanel
    case licenseSettings
    case activationSheet
    case featureGate(ProFeature)

    internal var parameterValue: String {
        switch self {
        case .supportWindow:
            return "app-support"
        case .aboutPanel:
            return "app-about"
        case .licenseSettings:
            return "app-settings"
        case .activationSheet:
            return "app-activation"
        case .featureGate(let feature):
            return "app-gate-" + Self.slug(for: feature)
        }
    }

    /// Derived from the case name rather than kept as a second hand-written list, so a new
    /// `ProFeature` cannot ship with a missing or stale slug.
    internal static func slug(for feature: ProFeature) -> String {
        feature.rawValue.reduce(into: "") { slug, character in
            if character.isUppercase, !slug.isEmpty {
                slug.append("-")
            }
            slug.append(contentsOf: character.lowercased())
        }
    }
}

/// The two places a person can pay for TablePro, and the only two outbound money links the app
/// opens.
internal enum SupportLinks {
    /// `appending(queryItems:)` writes the query ahead of the fragment, which is the only order
    /// that works: spelled `#pricing?ref=…` the whole tail is the fragment, so the parameter never
    /// reaches the server or `location.search` and nothing can read it.
    private static let pricingPage = URL(string: "https://tablepro.app/#pricing")!

    private static let sponsorsPage = URL(string: "https://github.com/sponsors/datlechin")!

    internal static func pricing(_ referrer: SupportReferrer) -> URL {
        pricingPage.appending(queryItems: [URLQueryItem(name: "ref", value: referrer.parameterValue)])
    }

    /// GitHub Sponsors ignores `ref` and reads `metadata_<key>`, which it reports in the
    /// sponsorship transaction export.
    internal static func sponsors(_ referrer: SupportReferrer) -> URL {
        sponsorsPage.appending(
            queryItems: [URLQueryItem(name: "metadata_campaign", value: referrer.parameterValue)]
        )
    }
}
