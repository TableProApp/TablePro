import Foundation
@testable import TablePro
import Testing

@MainActor
struct DeeplinkSettingsParsingTests {
    private func location(for link: String) throws -> SettingsLocation? {
        let url = try #require(URL(string: link))
        let outcome = URLClassifier.classify(url)
        guard case .some(.success(.openSettings(let location))) = outcome else {
            Issue.record("Expected .openSettings for \(link), got \(String(describing: outcome))")
            return nil
        }
        return location
    }

    @Test("A bare link asks for the last-used pane", arguments: ["tablepro://settings", "tablepro://settings/"])
    func bareLinkAsksForNoPane(link: String) throws {
        #expect(try location(for: link) == nil)
    }

    @Test("A known id opens its pane root")
    func knownIdOpensItsPane() throws {
        #expect(try location(for: "tablepro://settings/mcp") == .root(.mcp))
        #expect(try location(for: "tablepro://settings/plugins") == .root(.plugins))
        #expect(try location(for: "tablepro://settings/license") == .root(.account))
    }

    @Test(
        "An unknown pane id asks for the last-used pane instead of failing",
        arguments: ["tablepro://settings/nope", "tablepro://settings/MCP", "tablepro://settings/account"]
    )
    func unknownIdAsksForNoPane(link: String) throws {
        #expect(try location(for: link) == nil)
    }

    @Test("A page id opens that page", arguments: SettingsPage.allCases)
    func pageIdOpensThePage(page: SettingsPage) throws {
        let link = "tablepro://settings/\(page.parent.urlIdentifier)/\(page.urlIdentifier)"
        #expect(try location(for: link) == SettingsLocation(page: page))
    }

    @Test("An unknown second segment or a page of another pane opens the pane root")
    func unknownSecondSegmentOpensThePaneRoot() throws {
        #expect(try location(for: "tablepro://settings/mcp/authentication") == .root(.mcp))
        #expect(try location(for: "tablepro://settings/ai/providers/openai/") == .root(.ai))
        #expect(try location(for: "tablepro://settings/general/themes") == .root(.general))
        #expect(try location(for: "tablepro://settings/editor/SQL-Formatting") == .root(.editor))
    }

    @Test("plugins/<bundle id> opens that plugin's page, and an id that cannot be one opens Extensions")
    func pluginIdOpensItsPage() throws {
        #expect(
            try location(for: "tablepro://settings/plugins/com.TablePro.PostgreSQLDriver")
                == SettingsLocation(route: .plugin(id: "com.TablePro.PostgreSQLDriver"))
        )
        #expect(try location(for: "tablepro://settings/plugins/bad%20id") == .root(.plugins))
    }

    @Test("Query items are ignored")
    func queryIsIgnored() throws {
        #expect(try location(for: "tablepro://settings/sync?section=status") == .root(.sync))
        #expect(try location(for: "tablepro://settings?pane=mcp") == nil)
    }

    @Test("A percent-encoded id is decoded before matching")
    func percentEncodedIdIsDecoded() throws {
        #expect(try location(for: "tablepro://settings/%6Dcp") == .root(.mcp))
    }
}
