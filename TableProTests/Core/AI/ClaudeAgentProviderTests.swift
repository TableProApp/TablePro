//
//  ClaudeAgentProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ClaudeAgentProvider")
struct ClaudeAgentProviderTests {
    @Test("Inference arguments constrain the CLI to a chat backend and end with the prompt")
    func inferenceArgumentsConstrainTheAgent() {
        let args = ClaudeAgentProvider.inferenceArguments(
            prompt: "count the users",
            model: "sonnet",
            systemPrompt: "be terse",
            mcpConfigPath: nil
        )
        #expect(args.contains("-p"))
        #expect(args.contains("stream-json"))
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--disable-slash-commands"))
        #expect(args.contains("--model"))
        #expect(args.contains("sonnet"))
        #expect(args.contains("--system-prompt"))
        #expect(args.contains("be terse"))
        #expect(args.last == "count the users")
        #expect(args[args.count - 2] == "--")
    }

    @Test("Built-in tools are disabled so the CLI cannot touch the filesystem")
    func builtInToolsAreDisabled() {
        let args = ClaudeAgentProvider.inferenceArguments(
            prompt: "hi",
            model: "",
            systemPrompt: nil,
            mcpConfigPath: nil
        )
        guard let index = args.firstIndex(of: "--tools") else {
            Issue.record("--tools flag missing")
            return
        }
        #expect(args[index + 1] == "")
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains("--allowedTools"))
    }

    @Test("A prompt that looks like a flag is not parsed as an option")
    func promptThatLooksLikeFlagIsNotParsedAsOption() {
        let args = ClaudeAgentProvider.inferenceArguments(
            prompt: "--dangerously-skip-permissions",
            model: "",
            systemPrompt: nil,
            mcpConfigPath: nil
        )
        #expect(args[args.count - 2] == "--")
        #expect(args.last == "--dangerously-skip-permissions")
    }

    @Test("An MCP config path allows only TablePro's namespaced tools")
    func mcpConfigAllowsOnlyTableProTools() {
        let args = ClaudeAgentProvider.inferenceArguments(
            prompt: "hi",
            model: "",
            systemPrompt: nil,
            mcpConfigPath: "/tmp/config.json"
        )
        #expect(args.contains("--mcp-config"))
        #expect(args.contains("/tmp/config.json"))
        guard let index = args.firstIndex(of: "--allowedTools") else {
            Issue.record("--allowedTools flag missing")
            return
        }
        #expect(args[index + 1] == "mcp__tablepro__*")
    }

    @Test("Partial message deltas decode as incremental text")
    func partialMessageDeltasDecodeAsText() {
        let line = """
        {"type":"stream_event","event":{"delta":{"type":"text_delta","text":"SELECT"}}}
        """
        #expect(ClaudeAgentProvider.decodeEvent(line) == .text("SELECT"))
    }

    @Test("Non-text deltas and unknown event types are ignored")
    func unrelatedEventsAreIgnored() {
        let thinking = """
        {"type":"stream_event","event":{"delta":{"type":"thinking_delta","text":"hmm"}}}
        """
        #expect(ClaudeAgentProvider.decodeEvent(thinking) == nil)
        #expect(ClaudeAgentProvider.decodeEvent(#"{"type":"system","subtype":"init"}"#) == nil)
        #expect(ClaudeAgentProvider.decodeEvent("not json") == nil)
    }

    @Test("A failed result surfaces its message even when subtype claims success")
    func failedResultSurfacesMessage() {
        let line = """
        {"subtype":"success","is_error":true,"result":"Not logged in · Please run /login","type":"result"}
        """
        #expect(ClaudeAgentProvider.decodeEvent(line) == .failure("Not logged in · Please run /login"))
    }

    @Test("A successful result reports token usage")
    func successfulResultReportsUsage() {
        let line = """
        {"is_error":false,"type":"result","usage":{"input_tokens":120,"output_tokens":40}}
        """
        guard case .usage(let usage) = ClaudeAgentProvider.decodeEvent(line) else {
            Issue.record("expected usage event")
            return
        }
        #expect(usage.inputTokens == 120)
        #expect(usage.outputTokens == 40)
    }
}

@Suite("ClaudeAgentCLI")
struct ClaudeAgentCLITests {
    @Test("Auth status decodes a signed-in subscription account")
    func authStatusDecodesSubscription() {
        let output = """
        {"loggedIn":true,"authMethod":"claude.ai","email":"a@b.com","subscriptionType":"max"}
        """
        let status = ClaudeAgentCLI.decodeAuthStatus(output)
        #expect(status?.loggedIn == true)
        #expect(status?.accountDescription == "a@b.com")
        #expect(status?.planDescription == "Max")
    }

    @Test("Auth status tolerates leading banner noise from the shell")
    func authStatusTolerantOfNoise() {
        let output = "some banner\n{\"loggedIn\":false}\n"
        #expect(ClaudeAgentCLI.decodeAuthStatus(output)?.loggedIn == false)
        #expect(ClaudeAgentCLI.decodeAuthStatus("no json here") == nil)
    }

    @Test("Version parsing and the minimum version gate")
    func versionGate() {
        #expect(ClaudeAgentCLI.parseVersion("2.1.220 (Claude Code)") == "2.1.220")
        #expect(ClaudeAgentCLI.parseVersion("garbage") == nil)
        #expect(ClaudeAgentCLI.meetsMinimumVersion("2.1.220"))
        #expect(ClaudeAgentCLI.meetsMinimumVersion("2.2.0"))
        #expect(!ClaudeAgentCLI.meetsMinimumVersion("2.1.100"))
        #expect(!ClaudeAgentCLI.meetsMinimumVersion(nil))
    }

    @Test("Subscription auth is not silently overridden by an inherited API key")
    func subscriptionAuthIsNotOverriddenByInheritedKey() {
        let cli = ClaudeAgentCLI()
        let environment = cli.environment(
            additional: [:]
        )
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
    }
}

@Suite("AgentCLIDiscovery")
struct AgentCLIDiscoveryTests {
    @Test("The first executable candidate wins")
    func firstExecutableCandidateWins() {
        let discovery = AgentCLIDiscovery(
            candidatePaths: ["/nope/claude", "/yes/claude", "/also/claude"],
            isExecutable: { $0 == "/yes/claude" || $0 == "/also/claude" }
        )
        #expect(discovery.resolveExecutable(override: nil)?.path == "/yes/claude")
    }

    @Test("An override wins when executable and fails closed when not")
    func overrideWinsWhenExecutable() {
        let discovery = AgentCLIDiscovery(
            candidatePaths: ["/yes/claude"],
            isExecutable: { $0 == "/yes/claude" || $0 == "/custom/claude" }
        )
        #expect(discovery.resolveExecutable(override: "/custom/claude")?.path == "/custom/claude")
        #expect(discovery.resolveExecutable(override: "/missing/claude") == nil)
    }

    @Test("PATH composition puts preferred directories first and removes duplicates")
    func pathCompositionDeduplicates() {
        let path = AgentCLIDiscovery.composePath(
            preferred: ["/opt/homebrew/bin", "/usr/bin"],
            existing: "/usr/bin:/bin"
        )
        #expect(path == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    @Test("Node version directories sort numerically, not lexically")
    func nodeVersionsSortNumerically() {
        let directories = AgentCLIDiscovery.nodeVersionManagerDirectories(
            home: "/home",
            contentsOfDirectory: { _ in ["v9.0.0", "v20.11.1", "v18.0.0"] }
        )
        #expect(directories == ["/home/.nvm/versions/node/v20.11.1/bin"])
    }
}

@Suite("ClaudeAgentMCPBridge")
struct ClaudeAgentMCPBridgeTests {
    @Test("The MCP config carries the bearer token and TablePro's server name")
    func configCarriesScopedToken() throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:23508/mcp"))
        let payload = try #require(
            ClaudeAgentMCPBridge.configPayload(endpoint: endpoint, token: "tp_secret")
        )
        let json = try JSONSerialization.jsonObject(with: try #require(payload.data(using: .utf8)))
        let servers = try #require((json as? [String: Any])?["mcpServers"] as? [String: Any])
        let server = try #require(servers["tablepro"] as? [String: Any])
        #expect(server["type"] as? String == "http")
        #expect(server["url"] as? String == "http://127.0.0.1:23508/mcp")
        let headers = try #require(server["headers"] as? [String: String])
        #expect(headers["Authorization"] == "Bearer tp_secret")
    }
}

@Suite("ClaudeAgent registration")
struct ClaudeAgentRegistrationTests {
    @Test("Claude Agent needs no API key, so the settings sheet shows no key field")
    func claudeAgentUsesNoAPIKey() {
        #expect(AIProviderType.claudeAgent.authStyle == .none)
        #expect(!AIProviderType.claudeAgent.authStyle.usesAPIKey)
    }

    @Test("Claude Agent is registered and builds the CLI-backed transport")
    func claudeAgentIsRegistered() throws {
        AIProviderRegistration.registerAll()
        let descriptor = try #require(
            AIProviderRegistry.shared.descriptor(for: AIProviderType.claudeAgent.rawValue)
        )
        #expect(descriptor.displayName == "Claude Agent")
        #expect(!descriptor.allowsEndpointConfiguration)
        #expect(descriptor.curatedModels.map(\.id) == ["opus", "sonnet", "haiku"])

        let config = AIProviderConfig(type: .claudeAgent, model: "sonnet")
        #expect(descriptor.makeProvider(config, nil) is ClaudeAgentProvider)
    }
}
