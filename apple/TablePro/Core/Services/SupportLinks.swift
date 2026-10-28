//
//  SupportLinks.swift
//  TablePro
//

import Foundation

// Values stay inside alphanumerics, dashes and underscores, the characters GitHub Sponsors accepts.
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

    // From the case name, not the feature code, so the referrers the site already records stay the same.
    internal static func slug(for feature: ProFeature) -> String {
        String(describing: feature).reduce(into: "") { slug, character in
            if character.isUppercase, !slug.isEmpty {
                slug.append("-")
            }
            slug.append(contentsOf: character.lowercased())
        }
    }
}

internal enum SupportLinks {
    // `appending(queryItems:)` puts the query before the fragment; inside `#pricing?ref=` nothing reads it.
    private static let pricingPage = URL(string: "https://tablepro.app/#pricing")!

    private static let sponsorsPage = URL(string: "https://github.com/sponsors/datlechin")!

    internal static let licensingGuide = URL(string: "https://docs.tablepro.app/features/licensing")!

    internal static func pricing(_ referrer: SupportReferrer) -> URL {
        pricingPage.appending(queryItems: [URLQueryItem(name: "ref", value: referrer.parameterValue)])
    }

    // GitHub Sponsors ignores `ref` and reports `metadata_<key>` in its transaction export.
    internal static func sponsors(_ referrer: SupportReferrer) -> URL {
        sponsorsPage.appending(
            queryItems: [URLQueryItem(name: "metadata_campaign", value: referrer.parameterValue)]
        )
    }
}
