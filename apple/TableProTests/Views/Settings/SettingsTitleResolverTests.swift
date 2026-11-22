import Foundation
@testable import TablePro
import Testing

@MainActor
struct SettingsTitleResolverTests {
    @MainActor
    private final class Switches {
        var isAIEnabled = true
        var isMCPEnabled = true
        var isSignedIn = true
    }

    private let provider = AIProviderConfig(name: "Work Claude")

    private func resolver(_ switches: Switches, providers: [AIProviderConfig] = []) -> SettingsTitleResolver {
        SettingsTitleResolver(sources: SettingsTitleResolver.Sources(
            plugins: { [] },
            rejectedPlugins: { [] },
            providers: { providers },
            isSignedIn: { switches.isSignedIn },
            isAIEnabled: { switches.isAIEnabled },
            isMCPEnabled: { switches.isMCPEnabled },
            changes: { [] }
        ))
    }

    @Test("With AI on and MCP on, every page and a listed provider are available")
    func everythingAvailableWhenOn() {
        let titles = resolver(Switches(), providers: [provider])

        for page in SettingsPage.allCases {
            #expect(titles.isAvailable(.page(page)), "\(page)")
        }
        #expect(titles.isAvailable(.aiProvider(provider.id)))
        #expect(!titles.isAvailable(.aiProvider(UUID())))
    }

    @Test("With AI off, provider pages and Slash Commands are unavailable")
    func aiPagesFollowTheAISwitch() {
        let switches = Switches()
        switches.isAIEnabled = false
        let titles = resolver(switches, providers: [provider])

        #expect(!titles.isAvailable(.aiProvider(provider.id)))
        #expect(!titles.isAvailable(.page(.slashCommands)))
        #expect(titles.isAvailable(.page(.mcpTokens)))
        #expect(titles.title(for: .aiProvider(provider.id)) == "Work Claude")
    }

    @Test("Search offers a provider page only while AI is on")
    func providerSearchEntriesFollowTheAISwitch() {
        let switches = Switches()
        let titles = resolver(switches, providers: [provider])
        let entry = SettingsSearchEntry(title: "Work Claude", location: SettingsLocation(route: .aiProvider(provider.id)))

        #expect(titles.searchEntries == [entry])

        switches.isAIEnabled = false
        #expect(titles.searchEntries.isEmpty)
    }

    @Test("With the MCP server off, Approved Connections and Tokens are unavailable")
    func mcpPagesFollowTheServerSwitch() {
        let switches = Switches()
        switches.isMCPEnabled = false
        let titles = resolver(switches, providers: [provider])

        #expect(!titles.isAvailable(.page(.mcpApprovals)))
        #expect(!titles.isAvailable(.page(.mcpTokens)))
        #expect(titles.isAvailable(.page(.slashCommands)))
        #expect(titles.isAvailable(.aiProvider(provider.id)))
    }

    @Test("Devices and Teams follow sign-in, and the other Account pages stay")
    func accountPagesFollowSignIn() {
        let switches = Switches()
        switches.isSignedIn = false
        let titles = resolver(switches)

        #expect(!titles.isAvailable(.page(.accountDevices)))
        #expect(!titles.isAvailable(.page(.accountTeams)))
        #expect(titles.isAvailable(.page(.accountFeatures)))
        #expect(titles.isAvailable(.page(.accountOffline)))

        switches.isSignedIn = true
        #expect(titles.isAvailable(.page(.accountDevices)))
        #expect(titles.isAvailable(.page(.accountTeams)))
    }

    @Test("Back skips a Tokens entry while the MCP server is off and lands on the MCP root")
    func backSkipsMCPPagesWhileTheServerIsOff() {
        let switches = Switches()
        let titles = resolver(switches)
        let model = SettingsNavigationModel(initial: .root(.mcp), isRouteAvailable: { titles.isAvailable($0) })
        #expect(model.push(.page(.mcpTokens), in: .mcp))
        model.select(.general)

        switches.isMCPEnabled = false
        model.goBack()

        #expect(model.location == .root(.mcp))
    }

    @Test("A link to a provider page while AI is off opens the AI root")
    func providerLinkWithAIOffOpensTheRoot() {
        let switches = Switches()
        switches.isAIEnabled = false
        let titles = resolver(switches, providers: [provider])
        let model = SettingsNavigationModel(initial: .root(.general), isRouteAvailable: { titles.isAvailable($0) })

        model.open(SettingsLocation(route: .aiProvider(provider.id)), recordsHistory: true)

        #expect(model.location == .root(.ai))
    }
}
