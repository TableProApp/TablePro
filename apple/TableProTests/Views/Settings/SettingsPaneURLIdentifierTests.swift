import Foundation
@testable import TablePro
import Testing

struct SettingsPaneURLIdentifierTests {
    // Published at docs.tablepro.app/developers/url-scheme. Changing a value breaks links in other apps.
    private static let published: [SettingsPane: String] = [
        .general: "general",
        .sidebar: "sidebar",
        .connections: "connections",
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

    private static let publishedPages: [SettingsPage: String] = [
        .softwareUpdate: "general/software-update",
        .commandLineTool: "general/command-line-tool",
        .manageThemes: "appearance/themes",
        .linkedFolders: "connections/linked-folders",
        .trustedLinks: "connections/trusted-links",
        .sqlFormatting: "editor/sql-formatting",
        .filters: "data/filters",
        .queryHistory: "data/query-history",
        .dataRewind: "data/data-rewind",
        .slashCommands: "ai/slash-commands",
        .mcpApprovals: "mcp/approvals",
        .mcpTokens: "mcp/tokens",
        .accountFeatures: "license/features",
        .accountDevices: "license/devices",
        .accountTeams: "license/teams",
        .accountEncryption: "license/encryption",
        .accountOffline: "license/offline",
    ]

    private func location(_ path: String) -> SettingsLocation? {
        SettingsLocation(urlPathSegments: path.split(separator: "/").map(String.init))
    }

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
        #expect(SettingsPane.plugins.urlIdentifier == "plugins")
        #expect(SettingsPane.plugins.rawValue == "plugins")
    }

    @Test("Matching is exact and lowercase", arguments: ["MCP", "Mcp", " mcp", "mcp ", "Integrations", "integrations", ""])
    func matchingIsExact(raw: String) {
        #expect(SettingsPane(urlIdentifier: raw) == nil)
    }

    @Test("Every page has the published pane and page id")
    func everyPageHasThePublishedPath() {
        #expect(Self.publishedPages.count == SettingsPage.allCases.count)
        for page in SettingsPage.allCases {
            #expect("\(page.parent.urlIdentifier)/\(page.urlIdentifier)" == Self.publishedPages[page])
        }
    }

    @Test("Every page id opens its page", arguments: SettingsPage.allCases)
    func pageIdRoundTrips(page: SettingsPage) {
        #expect(SettingsLocation(urlPathSegments: [page.parent.urlIdentifier, page.urlIdentifier]) == SettingsLocation(page: page))
        #expect(SettingsPage(urlIdentifier: page.urlIdentifier, in: page.parent) == page)
    }

    @Test("Page ids are unique within their pane, and a page id under another pane is no page")
    func pageIdsAreScopedToTheirPane() {
        for pane in SettingsPane.allCases {
            let ids = SettingsPage.pages(in: pane).map(\.urlIdentifier)
            #expect(Set(ids).count == ids.count)
        }
        #expect(SettingsPage(urlIdentifier: "themes", in: .general) == nil)
        #expect(location("general/themes") == .root(.general))
    }

    @Test("A pane link opens the pane root")
    func paneLinksOpenTheRoot() {
        #expect(location("license") == .root(.account))
        #expect(location("plugins") == .root(.plugins))
        #expect(location("profiles") == .root(.profiles))
    }

    @Test("No segment or an unknown pane parses to nothing, so the last-used pane opens")
    func unknownPaneParsesToNothing() {
        #expect(SettingsLocation(urlPathSegments: []) == nil)
        #expect(location("nope") == nil)
        #expect(location("account/devices") == nil)
    }

    @Test("An unknown page, a wrong case or extra segments open the pane root")
    func unknownPageOpensThePaneRoot() {
        #expect(location("mcp/authentication") == .root(.mcp))
        #expect(location("ai/providers/openai") == .root(.ai))
        #expect(location("editor/SQL-Formatting") == .root(.editor))
        #expect(location("license/devices/extra") == SettingsLocation(page: .accountDevices))
    }

    @Test("plugins/<bundleId> opens that plugin's page")
    func pluginLinksOpenThePluginPage() {
        #expect(location("plugins/com.tablepro.postgresql") == SettingsLocation(route: .plugin(id: "com.tablepro.postgresql")))
        #expect(SettingsLocation(urlPathSegments: ["plugins", "not a bundle id"]) == .root(.plugins))
        #expect(SettingsLocation(urlPathSegments: ["plugins", ""]) == .root(.plugins))
    }

    @Test("Drill rows and page roots derive their identifiers from the page id")
    func accessibilityIdentifiersUseThePageId() {
        #expect(SettingsPage.sqlFormatting.drillIdentifier == "settings-drill-sql-formatting")
        #expect(SettingsPage.commandLineTool.pageIdentifier == "settings-page-command-line-tool")
        #expect(SettingsRoute.page(.mcpTokens).settingsDrillIdentifier == "settings-drill-tokens")
        #expect(SettingsRoute.page(.mcpApprovals).settingsDrillIdentifier == "settings-drill-approvals")
        #expect(SettingsRoute.plugin(id: "com.tablepro.postgresql").settingsDrillIdentifier == nil)
    }
}
