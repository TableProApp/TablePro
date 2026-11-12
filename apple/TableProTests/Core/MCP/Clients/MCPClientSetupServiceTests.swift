import Combine
import Foundation
@testable import TablePro
import TableProMCPClients
import Testing

@MainActor
struct MCPClientSetupServiceTests {
    @Test("Each client this Mac can run is listed with the state of its settings")
    func rowsCarryConfigStatus() async throws {
        let home = try MCPClientTestHome()
        try home.write(".editor/mcp.json", #"{ "mcpServers": { "tablepro": { "command": "\#(home.bridge.path)", "args": [] } } }"#)
        try home.write(".shared/config.toml", "[mcp_servers.tablepro]\ncommand = \"/Volumes/Gone/TablePro.app/Contents/MacOS/tablepro-mcp\"\nargs = []\n")
        let harness = try MCPClientServiceHarness(
            home: home,
            workspace: FakeMCPClientWorkspace(installedBundleIDs: ["com.example.desk"])
        )

        await harness.service.refresh()

        let service = harness.service
        #expect(service.rows.map { $0.id } == ["editor", "agent", "desk", "term", "remote"])
        #expect(service.row(id: "editor")?.config == .current)
        #expect(service.row(id: "agent")?.config == .notConfigured)
        #expect(service.row(id: "agent")?.isInstalled == false)
        #expect(service.row(id: "desk")?.config == .moved)
        #expect(service.row(id: "desk")?.isInstalled == true)
        #expect(service.row(id: "term")?.config == .moved)
        #expect(service.row(id: "remote")?.unsupported == .remoteOnly)
    }

    @Test("Install takes the first method this Mac offers, in the catalog's order")
    func installRouteFollowsAvailability() async throws {
        let home = try MCPClientTestHome()
        try home.makeFolder(".editor")

        let withHandler = try MCPClientServiceHarness(home: home, workspace: FakeMCPClientWorkspace(handledSchemes: ["editor"]))
        await withHandler.service.refresh()
        #expect(withHandler.service.row(id: "editor")?.installRoute == .deeplink(scheme: "editor"))

        try home.makeExecutable(".local/bin/editor")
        let withCommand = try MCPClientServiceHarness(home: home)
        await withCommand.service.refresh()
        #expect(withCommand.service.row(id: "editor")?.installRoute == .cli(binary: "editor"))

        try home.remove(".local/bin/editor")
        let withFileOnly = try MCPClientServiceHarness(home: home)
        await withFileOnly.service.refresh()
        #expect(withFileOnly.service.row(id: "editor")?.installRoute == .file)

        try home.remove(".editor")
        let notFound = try MCPClientServiceHarness(home: home)
        await notFound.service.refresh()
        let row = try #require(notFound.service.row(id: "editor"))
        #expect(row.installRoute == .copy)
        #expect(notFound.service.presentation(for: row).action == .copy)
    }

    @Test("Updating a client whose command cannot replace removes first, and a missing entry counts as removed")
    func removeThenAddUpdate() async throws {
        let home = try MCPClientTestHome()
        try home.makeExecutable("bin/agent")
        try home.write(".agent.json", #"{ "mcpServers": { "tablepro": { "type": "stdio", "command": "/Volumes/Gone/tablepro-mcp", "args": [] } } }"#)
        let runner = FakeMCPClientRunner(replies: [
            MCPClientCommandResult(exitCode: 1, output: "No MCP server named tablepro found in user config"),
            MCPClientCommandResult(exitCode: 0, output: "Added stdio MCP server tablepro to user config")
        ])
        let harness = try MCPClientServiceHarness(home: home, runner: runner)
        await harness.service.refresh()
        let row = try #require(harness.service.row(id: "agent"))
        #expect(row.config == .moved)
        #expect(MCPClientRowPresentation.action(row: row) == .update(handsOff: false))

        let outcome = await harness.service.update("agent")

        #expect(outcome == .done(backupPath: nil))
        #expect(runner.calls.map { $0.arguments } == [
            ["mcp", "remove", "--scope", "user", "tablepro"],
            ["mcp", "add", "--scope", "user", "tablepro", "--", home.bridge.path]
        ])
        #expect(runner.calls.allSatisfy { $0.executable == home.url("bin/agent").path })
        #expect(runner.calls.allSatisfy { $0.home == home.path })
    }

    @Test("A command that fails keeps its output for the detail area")
    func failedCommandKeepsOutput() async throws {
        let home = try MCPClientTestHome()
        try home.makeExecutable("bin/agent")
        let runner = FakeMCPClientRunner(replies: [MCPClientCommandResult(exitCode: 2, output: "permission denied\n")])
        let harness = try MCPClientServiceHarness(home: home, runner: runner)
        await harness.service.refresh()

        let outcome = await harness.service.install("agent")

        guard case let .failed(_, output) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(output == "permission denied")
        let row = try #require(harness.service.row(id: "agent"))
        #expect(harness.service.presentation(for: row).status == String(localized: "Couldn't install"))
    }

    @Test("A copy running from a disk image refuses to install and writes nothing")
    func readOnlyVolumeRefuses() async throws {
        let home = try MCPClientTestHome()
        try home.makeFolder(".editor")
        try home.makeExecutable("bin/agent")
        let runner = FakeMCPClientRunner()
        let harness = try MCPClientServiceHarness(home: home, runner: runner, isAppOnReadOnlyVolume: true)
        await harness.service.refresh()

        #expect(await harness.service.install("editor") == .refusedReadOnlyVolume)
        #expect(await harness.service.install("agent") == .refusedReadOnlyVolume)
        #expect(home.read(".editor/mcp.json") == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test("Install merges TablePro into the settings file and Remove takes only its entry out")
    func fileInstallAndRemove() async throws {
        let home = try MCPClientTestHome()
        try home.write(".editor/mcp.json", #"{ "mcpServers": { "other": { "command": "other-server" } } }"#)
        let harness = try MCPClientServiceHarness(home: home)
        await harness.service.refresh()
        #expect(harness.service.row(id: "editor")?.installRoute == .file)

        let installed = await harness.service.install("editor")

        guard case .done(let backup) = installed else {
            Issue.record("Expected the install to finish, got \(installed)")
            return
        }
        #expect(backup?.hasSuffix("mcp.json.tablepro-backup") == true)
        let servers = try Self.servers(in: try #require(home.read(".editor/mcp.json")))
        #expect((servers["tablepro"] as? [String: Any])?["command"] as? String == home.bridge.path)
        #expect((servers["other"] as? [String: Any])?["command"] as? String == "other-server")
        #expect(harness.service.row(id: "editor")?.config == .current)
        #expect(harness.service.row(id: "editor")?.removeRoute == .file)

        let removed = await harness.service.remove("editor")

        guard case .done = removed else {
            Issue.record("Expected the removal to finish, got \(removed)")
            return
        }
        let remaining = try Self.servers(in: try #require(home.read(".editor/mcp.json")))
        #expect(remaining["tablepro"] == nil)
        #expect(remaining["other"] != nil)
        #expect(harness.service.row(id: "editor")?.config == .notConfigured)
    }

    @Test("A deeplink install hands off to the client and waits for it to confirm")
    func deeplinkHandsOff() async throws {
        let home = try MCPClientTestHome()
        let workspace = FakeMCPClientWorkspace(installedBundleIDs: ["com.example.editor"], handledSchemes: ["editor"])
        let harness = try MCPClientServiceHarness(home: home, workspace: workspace)
        await harness.service.refresh()

        #expect(await harness.service.install("editor") == .handedOff)

        let opened = try #require(workspace.opened.first)
        #expect(opened.scheme == "editor")
        #expect(opened.absoluteString.contains("name=tablepro"))
        let row = try #require(harness.service.row(id: "editor"))
        #expect(harness.service.presentation(for: row).status == String(format: String(localized: "Finish in %@"), "Editor"))
    }

    @Test("A client that connects while the sheet is open reads Connected just now and is announced once")
    func newSessionIsAnnounced() async throws {
        let home = try MCPClientTestHome()
        let harness = try MCPClientServiceHarness(home: home)
        await harness.service.refresh()
        let open = MCPClientSessionSighting(id: "open", clientInfoName: "agent-cli", tokenName: MCPTokenStore.stdioBridgeTokenName)

        harness.sessions.send([open])

        #expect(harness.service.connection(for: "agent") == .connected)
        #expect(harness.announcements.messages.isEmpty)

        harness.sessions.send([
            open,
            MCPClientSessionSighting(
                id: "new", clientInfoName: "shared-client", displayName: "Shared", tokenName: MCPTokenStore.stdioBridgeTokenName
            )
        ])

        #expect(harness.service.connection(for: "desk") == .justConnected)
        #expect(harness.service.connection(for: "term") == .justConnected)
        #expect(harness.service.connection(for: "agent") == .connected)
        #expect(harness.announcements.messages == [String(format: String(localized: "%@ connected"), "Shared")])
        let desk = try #require(harness.service.row(id: "desk"))
        #expect(harness.service.presentation(for: desk).status == String(localized: "Connected just now"))
    }

    @Test("A session two rows share is announced by the one found on this Mac")
    func sharedSessionNamesTheClientFoundHere() async throws {
        let home = try MCPClientTestHome()
        try home.makeFolder(".shared")
        let harness = try MCPClientServiceHarness(home: home)
        await harness.service.refresh()
        #expect(harness.service.row(id: "term")?.isDetected == true)
        #expect(harness.service.row(id: "desk")?.isDetected == false)

        harness.sessions.send([])
        harness.sessions.send([
            MCPClientSessionSighting(
                id: "new", clientInfoName: "shared-client", displayName: "Shared", tokenName: MCPTokenStore.stdioBridgeTokenName
            )
        ])

        #expect(harness.announcements.messages == [String(format: String(localized: "%@ connected"), "Term")])
        #expect(harness.service.connection(for: "term") == .justConnected)
        #expect(harness.service.connection(for: "desk") == .notConnected)
    }

    @Test("A session already open when the sheet opens lights only the row found here once the rows are read")
    func sharedSessionSettlesOnRefresh() async throws {
        let home = try MCPClientTestHome()
        try home.makeFolder(".shared")
        let harness = try MCPClientServiceHarness(home: home)
        harness.sessions.send([
            MCPClientSessionSighting(id: "open", clientInfoName: "shared-client", tokenName: MCPTokenStore.stdioBridgeTokenName)
        ])
        #expect(harness.service.connection(for: "desk") == .connected)
        #expect(harness.service.connection(for: "term") == .connected)

        await harness.service.refresh()

        #expect(harness.service.connection(for: "term") == .connected)
        #expect(harness.service.connection(for: "desk") == .notConnected)
    }

    @Test("A clientInfo name two rows share names one of them only when it alone is on this Mac")
    func sharedSessionAttribution() throws {
        let catalog = try MCPClientSetupFixture.catalog()
        let bridge = MCPTokenStore.stdioBridgeTokenName
        #expect(catalog.client(forSessionNamed: "shared-client", tokenName: bridge, detected: ["term"])?.id == "term")
        #expect(catalog.client(forSessionNamed: "shared-client", tokenName: bridge, detected: []) == nil)
        #expect(catalog.client(forSessionNamed: "shared-client", tokenName: bridge, detected: ["desk", "term"]) == nil)
        #expect(catalog.clientIDs(forSessionNamed: "shared-client", tokenName: bridge, detected: []) == ["desk", "term"])
        #expect(catalog.clientIDs(forSessionNamed: "shared-client", tokenName: bridge, detected: ["desk"]) == ["desk"])
        #expect(catalog.iconSlug(forSessionNamed: "shared-client", tokenName: bridge, detected: ["desk"]) == "desk")
        #expect(catalog.iconSlug(forSessionNamed: "shared-client", tokenName: bridge, detected: []) == nil)
        #expect(catalog.client(forSessionNamed: "editor-client", tokenName: bridge, detected: [])?.id == "editor")
        let sessions = [(clientInfoName: "shared-client", tokenName: Optional(bridge)), (clientInfoName: "editor-client", tokenName: Optional(bridge))]
        #expect(catalog.ambiguousClientIDs(forSessionsNamed: sessions) == ["desk", "term"])
    }

    @Test("An old setup in a project names the project and offers no Remove; a project folder that is gone is ignored")
    func shadowedProject() async throws {
        let home = try MCPClientTestHome()
        try home.makeExecutable("bin/agent")
        try home.makeFolder("work/shop")
        func agentConfig(project: String) -> String {
            """
            { "projects": { "\(project)": { "mcpServers": { "tablepro": { "command": "/Volumes/Gone/tablepro-mcp" } } } },
              "mcpServers": { "tablepro": { "type": "stdio", "command": "\(home.bridge.path)", "args": [] } } }
            """
        }
        try home.write(".agent.json", agentConfig(project: home.url("work/gone").path))
        let harness = try MCPClientServiceHarness(home: home)
        await harness.service.refresh()
        #expect(harness.service.row(id: "agent")?.config == .current)
        #expect(harness.service.row(id: "agent")?.removeRoute == .cli(binary: "agent"))

        try home.write(".agent.json", agentConfig(project: home.url("work/shop").path))
        await harness.service.refresh()

        let row = try #require(harness.service.row(id: "agent"))
        #expect(row.config == .shadowed(project: "~/work/shop"))
        #expect(row.removeRoute == nil)
        #expect(await harness.service.remove("agent") == .unavailable)
        #expect(MCPClientDetailText.configState(row.config, name: row.name)?.contains("~/work/shop") == true)
    }

    @Test("Update rewrites how the entry reaches TablePro and keeps the tool list the user narrowed")
    func updateKeepsRestrictions() async throws {
        let home = try MCPClientTestHome()
        try home.write(".editor/mcp.json", """
        { "mcpServers": { "tablepro": { "command": "/Volumes/Gone/TablePro.app/Contents/MacOS/tablepro-mcp", "args": [], "tools": ["list_connections"] } } }
        """)
        let harness = try MCPClientServiceHarness(home: home)
        await harness.service.refresh()
        #expect(harness.service.row(id: "editor")?.config == .moved)

        #expect(Self.isDone(await harness.service.update("editor")))

        let text = try #require(home.read(".editor/mcp.json"))
        let server = try #require(try Self.servers(in: text)["tablepro"] as? [String: Any])
        #expect(server["command"] as? String == home.bridge.path)
        #expect(server["tools"] as? [String] == ["list_connections"])
        #expect(harness.service.row(id: "editor")?.config == .current)
    }

    @Test("A setup made with a token or turned off in the client is never replaced by Install or Update")
    func userChoicesAreKept() async throws {
        let home = try MCPClientTestHome()
        let token = #"{ "mcpServers": { "tablepro": { "url": "http://127.0.0.1:23508/mcp", "headers": { "Authorization": "Bearer tp_x" } } } }"#
        try home.write(".editor/mcp.json", token)
        let turnedOff = "[mcp_servers.tablepro]\ncommand = \"\(home.bridge.path)\"\nargs = []\nenabled = false\n"
        try home.write(".shared/config.toml", turnedOff)
        let harness = try MCPClientServiceHarness(home: home)
        await harness.service.refresh()

        let editor = try #require(harness.service.row(id: "editor"))
        #expect(editor.config == .usesToken)
        #expect(harness.service.presentation(for: editor).action == nil)
        #expect(harness.service.presentation(for: editor).status == String(localized: "Set up with a token"))
        #expect(await harness.service.update("editor") == .unavailable)
        #expect(await harness.service.install("editor") == .unavailable)
        #expect(home.read(".editor/mcp.json") == token)

        let term = try #require(harness.service.row(id: "term"))
        #expect(term.config == .disabled)
        #expect(harness.service.presentation(for: term).action == nil)
        #expect(harness.service.presentation(for: term).status == String(localized: "Turned off"))
        #expect(await harness.service.update("term") == .unavailable)
        #expect(home.read(".shared/config.toml") == turnedOff)
    }

    @Test("Update merges into the settings file and keeps the keys the user added, even when the client's command exists")
    func updateMergesFile() async throws {
        let home = try MCPClientTestHome()
        try home.makeExecutable(".local/bin/editor")
        try home.write(".editor/mcp.json", """
        {
          "mcpServers": {
            "tablepro": {
              "command": "/Volumes/Gone/TablePro.app/Contents/MacOS/tablepro-mcp",
              "args": [],
              "autoApprove": ["list_connections"],
              "timeout": 30
            }
          }
        }
        """)
        try home.write(".shared/config.toml", """
        [mcp_servers.tablepro]
        command = "/Volumes/Gone/TablePro.app/Contents/MacOS/tablepro-mcp"
        args = []
        enabled_tools = ["list_connections"]
        startup_timeout_sec = 30

        [mcp_servers.tablepro.env]
        TOKEN = "x"

        """)
        let runner = FakeMCPClientRunner()
        let harness = try MCPClientServiceHarness(home: home, runner: runner)
        await harness.service.refresh()
        #expect(harness.service.row(id: "editor")?.updateRoute == .file)

        #expect(Self.isDone(await harness.service.update("editor")))
        #expect(Self.isDone(await harness.service.update("term")))

        #expect(runner.calls.isEmpty)
        let editorText = try #require(home.read(".editor/mcp.json"))
        let server = try #require(try Self.servers(in: editorText)["tablepro"] as? [String: Any])
        #expect(server["command"] as? String == home.bridge.path)
        #expect(server["autoApprove"] as? [String] == ["list_connections"])
        #expect(server["timeout"] as? Int == 30)
        #expect(home.read(".shared/config.toml") == """
        [mcp_servers.tablepro]
        command = "\(home.bridge.path)"
        args = []
        enabled_tools = ["list_connections"]
        startup_timeout_sec = 30

        [mcp_servers.tablepro.env]
        TOKEN = "x"

        """)
        #expect(harness.service.row(id: "editor")?.config == .current)
        #expect(harness.service.row(id: "term")?.config == .current)
    }

    @Test("A write the system refuses names the file, and keeps the system's reason as output")
    func refusedWriteIsReadable() async throws {
        let home = try MCPClientTestHome()
        try home.write(".editor/mcp.json", #"{ "mcpServers": {} }"#)
        let folder = home.url(".editor").path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.url(".editor").path) }
        let harness = try MCPClientServiceHarness(home: home)
        await harness.service.refresh()

        let outcome = await harness.service.install("editor")

        guard case let .failed(message, output) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(message == String(format: String(localized: "TablePro could not write %@."), "mcp.json"))
        #expect(output?.contains("NSCocoaErrorDomain") == true)
        #expect(MCPClientSetupService.message(for: MCPConfigWriteError.io("x"), fileName: "mcp.json") == message)
    }

    @Test("A session from TablePro's own Claude Agent lights no client")
    func agentSessionIsNotAClient() async throws {
        let home = try MCPClientTestHome()
        let harness = try MCPClientServiceHarness(home: home)
        await harness.service.refresh()

        harness.sessions.send([])
        harness.sessions.send([
            MCPClientSessionSighting(id: "turn", clientInfoName: "agent-cli", tokenName: MCPTokenStore.claudeAgentTokenName)
        ])

        #expect(harness.service.connection(for: "agent") == .notConnected)
        #expect(harness.announcements.messages.isEmpty)
    }

    @Test("A removal the client reports as already gone counts as done")
    func missingEntryReadsAsRemoved() {
        #expect(MCPClientSetupService.reportsMissingEntry("No MCP server named tablepro found in user config"))
        #expect(MCPClientSetupService.reportsMissingEntry("Error: server \"tablepro\" not found"))
        #expect(!MCPClientSetupService.reportsMissingEntry("EACCES: permission denied"))
    }

    private static func isDone(_ outcome: MCPClientActionOutcome) -> Bool {
        if case .done = outcome { return true }
        return false
    }

    private static func servers(in text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return try #require(object?["mcpServers"] as? [String: Any])
    }
}
