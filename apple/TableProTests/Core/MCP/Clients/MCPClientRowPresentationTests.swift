import Foundation
@testable import TablePro
import TableProMCPClients
import Testing

struct MCPClientRowPresentationTests {
    private func row(
        config: MCPClientConfigState = .notConfigured,
        isInstalled: Bool = true,
        installRoute: MCPClientRoute = .file,
        updateRoute: MCPClientRoute = .file,
        removeRoute: MCPClientRoute? = nil,
        unsupported: MCPClientUnsupported? = nil,
        isConfigWritable: Bool = true,
        commandLine: String? = nil
    ) -> MCPClientRow {
        MCPClientRow(
            id: "cursor",
            name: "Cursor",
            iconSlug: "cursor",
            isDetected: isInstalled,
            isInstalled: isInstalled,
            config: config,
            installRoute: installRoute,
            updateRoute: updateRoute,
            removeRoute: removeRoute,
            unsupported: unsupported,
            applies: .live,
            configPath: "/Users/me/.cursor/mcp.json",
            displayConfigPath: "~/.cursor/mcp.json",
            configFileExists: true,
            isConfigWritable: isConfigWritable,
            snippet: "{}",
            commandLine: commandLine
        )
    }

    private func present(
        _ row: MCPClientRow,
        activity: MCPClientActivity? = nil,
        connection: MCPClientConnection = .notConnected
    ) -> MCPClientRowPresentation {
        MCPClientRowPresentation(row: row, activity: activity, connection: connection)
    }

    @Test("A client that hands off to its own app offers Install with an ellipsis")
    func deeplinkInstall() {
        let presentation = present(row(installRoute: .deeplink(scheme: "cursor")))
        #expect(presentation.action == .install(handsOff: true))
        #expect(presentation.action?.title == String(localized: "Install…"))
        #expect(presentation.subtitle == String(format: String(localized: "Opens %@ to confirm"), "Cursor"))
        #expect(presentation.status == nil)
    }

    @Test("A client set up through its command or its file offers a plain Install")
    func inPlaceInstall() {
        let viaCommand = present(row(installRoute: .cli(binary: "claude")))
        #expect(viaCommand.action?.title == String(localized: "Install"))
        #expect(viaCommand.subtitle == String(format: String(localized: "Adds through the %@ command"), "claude"))

        let viaFile = present(row(installRoute: .file))
        #expect(viaFile.action == .install(handsOff: false))
        #expect(viaFile.subtitle == String(format: String(localized: "Edits %@"), "~/.cursor/mcp.json"))
    }

    @Test("A client set up for this copy offers no button and never offers Remove as one")
    func currentHasNoButton() {
        let presentation = present(row(config: .current, removeRoute: .file))
        #expect(presentation.action == nil)
        #expect(presentation.status == String(localized: "Set up"))
    }

    @Test("A client set up for a moved or other copy offers Update")
    func staleOffersUpdate() {
        let moved = present(row(config: .moved))
        #expect(moved.action == .update(handsOff: false))
        #expect(moved.status == String(localized: "TablePro moved"))

        let otherCopy = present(row(config: .otherCopy, updateRoute: .deeplink(scheme: "cursor")))
        #expect(otherCopy.action?.title == String(localized: "Update…"))
        #expect(otherCopy.status == String(localized: "Uses another copy"))
    }

    @Test("A client that is not on this Mac offers Copy")
    func notFoundOffersCopy() {
        let presentation = present(row(isInstalled: false, installRoute: .copy, updateRoute: .copy))
        #expect(presentation.action == .copy)
        #expect(presentation.status == String(localized: "Not found"))
        #expect(presentation.subtitle == String(format: String(localized: "Copy the setup into %@"), "~/.cursor/mcp.json"))
    }

    @Test("A settings file TablePro cannot read is never written, so the row offers Copy")
    func unreadableOffersCopy() {
        let presentation = present(row(config: .unreadable, installRoute: .file))
        #expect(presentation.action == .copy)
        #expect(presentation.status == String(localized: "Can't read settings"))
    }

    @Test("A client that cannot reach a local server says why and offers nothing")
    func unsupportedHasNoAction() {
        let presentation = present(row(unsupported: .remoteOnly), connection: .connected)
        #expect(presentation.action == nil)
        #expect(presentation.status == nil)
        #expect(presentation.subtitle == String(localized: "Reaches only servers on the internet"))
    }

    @Test("A running action replaces the button and names what it does")
    func busyRow() {
        let presentation = present(row(), activity: .running(.install))
        #expect(presentation.isBusy)
        #expect(presentation.action == nil)
        #expect(presentation.status == String(localized: "Installing…"))
    }

    @Test("A live session outranks the settings status, and a new one reads just now")
    func connectionStatus() {
        #expect(present(row(config: .current), connection: .connected).status == String(localized: "Connected"))
        #expect(present(row(config: .current), connection: .justConnected).status == String(localized: "Connected just now"))
    }

    @Test("A failed action stays on the row until the next one")
    func failedStatus() {
        let presentation = present(row(config: .moved), activity: .failed(.update, message: "boom", output: nil))
        #expect(presentation.status == String(localized: "Couldn't update"))
        #expect(presentation.action == .update(handsOff: false))
    }

    @Test("A file only the client writes is copied as its command")
    func commandOnlyCopy() {
        let claudeCode = row(isConfigWritable: false, commandLine: "claude mcp add --scope user tablepro -- /x")
        #expect(claudeCode.copyText == "claude mcp add --scope user tablepro -- /x")
        #expect(row(commandLine: "codex mcp add tablepro -- /x").copyText == "{}")
    }

    @Test("A token setup, a setup turned off in the client and a project override offer no button")
    func userChoicesHaveNoButton() {
        let token = present(row(config: .usesToken, removeRoute: .file))
        #expect(token.action == nil)
        #expect(token.status == String(localized: "Set up with a token"))
        #expect(MCPClientDetailText.configState(.usesToken, name: "Cursor") != nil)

        let off = present(row(config: .disabled))
        #expect(off.action == nil)
        #expect(off.status == String(localized: "Turned off"))
        #expect(MCPClientDetailText.configState(.disabled, name: "Cursor") != nil)

        let shadowed = present(row(config: .shadowed(project: "~/work/shop")))
        #expect(shadowed.action == nil)
        #expect(shadowed.status == String(localized: "Old setup in a project"))
        #expect(MCPClientDetailText.configState(.shadowed(project: "~/work/shop"), name: "Cursor")?.contains("~/work/shop") == true)
    }

    @Test("The engine's statuses map to row states that keep the entry")
    func statusMapping() {
        #expect(MCPClientConfigState(.usesToken) == .usesToken)
        #expect(MCPClientConfigState(.disabled) == .disabled)
        let shadowed = MCPClientConfigState(.stale(.shadowed(scope: "/Users/me/shop"))) { $0.replacingOccurrences(of: "/Users/me", with: "~") }
        #expect(shadowed == .shadowed(project: "~/shop"))
        #expect(MCPClientConfigState.usesToken.hasEntry)
        #expect(!MCPClientConfigState.usesToken.needsUpdate)
        #expect(!MCPClientConfigState.shadowed(project: "~/shop").needsUpdate)
        #expect(MCPClientConfigState.usesToken.isUserChoice)
        #expect(MCPClientConfigState.disabled.isUserChoice)
        #expect(!MCPClientConfigState.otherCopy.isUserChoice)
    }

    @Test("Each row button's spoken label names its client")
    func accessibilityLabels() {
        let labels = [
            MCPClientRowAction.install(handsOff: true).accessibilityLabel(clientName: "Cursor"),
            MCPClientRowAction.update(handsOff: false).accessibilityLabel(clientName: "Cursor"),
            MCPClientRowAction.copy.accessibilityLabel(clientName: "Cursor"),
        ]
        #expect(labels.allSatisfy { $0.contains("Cursor") })
        #expect(Set(labels).count == 3)
        #expect(MCPClientRowAction.install(handsOff: false).accessibilityLabel(clientName: "Zed")
            != MCPClientRowAction.install(handsOff: false).accessibilityLabel(clientName: "Cursor"))
    }
}
