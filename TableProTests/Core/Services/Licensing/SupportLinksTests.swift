//
//  SupportLinksTests.swift
//  TablePro
//
//  The attribution parameter is the one part of the support links that can rot in silence: a link
//  that opens the right page with the wrong shape looks identical to a working one.
//

import Foundation
@testable import TablePro
import Testing

@Suite("SupportLinks")
struct SupportLinksTests {
    private static let everyReferrer: [SupportReferrer] =
        [.supportWindow, .aboutPanel, .licenseSettings, .activationSheet]
            + ProFeature.allCases.map { .featureGate($0) }

    private static func components(_ url: URL) -> URLComponents? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)
    }

    @Test("Every pricing link carries its ref in the query and still lands on the pricing section")
    func pricingLinksAreTagged() throws {
        for referrer in Self.everyReferrer {
            let url = SupportLinks.pricing(referrer)
            let parts = try #require(Self.components(url))

            #expect(parts.host == "tablepro.app")
            #expect(parts.fragment == "pricing")
            #expect(parts.queryItems == [URLQueryItem(name: "ref", value: referrer.parameterValue)])
        }
    }

    /// Written `#pricing?ref=…` the parameter is part of the fragment, which never reaches the
    /// server and never appears in `location.search`, so nothing can read it. The query has to
    /// come first.
    @Test("No pricing link hides its parameter inside the fragment")
    func pricingQueryPrecedesTheFragment() throws {
        for referrer in Self.everyReferrer {
            let address = SupportLinks.pricing(referrer).absoluteString
            let query = try #require(address.firstIndex(of: "?"))
            let fragment = try #require(address.firstIndex(of: "#"))

            #expect(query < fragment)
        }
    }

    /// GitHub Sponsors reads `metadata_<key>` and ignores `ref`, and it caps a value at 100
    /// characters of alphanumerics, dashes and underscores.
    @Test("Every sponsor link uses the parameter GitHub Sponsors actually records")
    func sponsorLinksUseGitHubMetadata() throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

        for referrer in Self.everyReferrer {
            let url = SupportLinks.sponsors(referrer)
            let parts = try #require(Self.components(url))

            #expect(parts.host == "github.com")
            #expect(parts.path == "/sponsors/datlechin")
            #expect(parts.queryItems == [URLQueryItem(name: "metadata_campaign", value: referrer.parameterValue)])
            #expect(referrer.parameterValue.count <= 100)
            #expect(referrer.parameterValue.unicodeScalars.allSatisfy { allowed.contains($0) })
        }
    }

    @Test("Every referrer names a different place")
    func referrerValuesAreDistinct() {
        let values = Self.everyReferrer.map(\.parameterValue)

        #expect(Set(values).count == values.count)
    }

    @Test("A gated feature's slug is derived from its case name")
    func featureSlugsAreKebabCased() {
        #expect(SupportReferrer.featureGate(.queryInsights).parameterValue == "app-gate-query-insights")
        #expect(SupportReferrer.featureGate(.iCloudSync).parameterValue == "app-gate-i-cloud-sync")
        #expect(SupportReferrer.featureGate(.compareSync).parameterValue == "app-gate-compare-sync")
    }

    @Test("No support link states a price, which only the checkout may do")
    func linksNeverCarryAPrice() {
        for referrer in Self.everyReferrer {
            #expect(!SupportLinks.pricing(referrer).absoluteString.contains("$"))
            #expect(!SupportLinks.sponsors(referrer).absoluteString.contains("$"))
        }
    }
}
