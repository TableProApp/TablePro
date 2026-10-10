//
//  SettingsPaneURLIdentifierTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct SettingsPaneURLIdentifierTests {
    // Published in docs/developers/url-scheme.mdx. Changing a value breaks links in other apps.
    private static let published: [SettingsPane: String] = [
        .general: "general",
        .appearance: "appearance",
        .editor: "editor",
        .data: "data",
        .keyboard: "keyboard",
        .profiles: "profiles",
        .notifications: "notifications",
        .ai: "ai",
        .mcp: "mcp",
        .plugins: "plugins",
        .sync: "sync",
        .account: "license",
    ]

    @Test("Every pane has the published id")
    func everyPaneHasThePublishedId() {
        #expect(Self.published.count == SettingsPane.allCases.count)
        for pane in SettingsPane.allCases {
            #expect(pane.urlIdentifier == Self.published[pane])
        }
    }

    @Test("Every id maps back to its pane", arguments: SettingsPane.allCases)
    func roundTrip(pane: SettingsPane) {
        #expect(SettingsPane(urlIdentifier: pane.urlIdentifier) == pane)
    }

    @Test("Ids are unique")
    func idsAreUnique() {
        let ids = SettingsPane.allCases.map(\.urlIdentifier)
        #expect(Set(ids).count == ids.count)
    }

    @Test("The License pane is license, not its stored rawValue")
    func licenseIsIndependentOfRawValue() {
        #expect(SettingsPane.account.urlIdentifier == "license")
        #expect(SettingsPane(urlIdentifier: "license") == .account)
        #expect(SettingsPane(urlIdentifier: "account") == nil)
    }

    @Test("Matching is exact and lowercase", arguments: ["MCP", "Mcp", " mcp", "mcp ", "Integrations", "integrations", ""])
    func matchingIsExact(raw: String) {
        #expect(SettingsPane(urlIdentifier: raw) == nil)
    }
}
