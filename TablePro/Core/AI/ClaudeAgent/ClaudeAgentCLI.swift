//
//  ClaudeAgentCLI.swift
//  TablePro
//

import Foundation
import os

struct ClaudeAgentAuthStatus: Decodable, Equatable, Sendable {
    let loggedIn: Bool
    let authMethod: String?
    let email: String?
    let subscriptionType: String?

    static let signedOut = ClaudeAgentAuthStatus(
        loggedIn: false,
        authMethod: nil,
        email: nil,
        subscriptionType: nil
    )

    var accountDescription: String? {
        guard loggedIn else { return nil }
        if let email, !email.isEmpty { return email }
        return authMethod
    }

    var planDescription: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        return subscriptionType.capitalized
    }
}

struct ClaudeAgentCLI: Sendable {
    static let toolName = "claude"
    static let installCommand = "npm install -g @anthropic-ai/claude-code"
    static let minimumVersion = "2.1.205"

    private static let logger = Logger(subsystem: "com.TablePro", category: "ClaudeAgentCLI")
    private static let subscriptionOverridingKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN"
    ]

    private let discovery: AgentCLIDiscovery
    private let process: AgentCLIProcess
    private let executableOverride: String?

    init(executableOverride: String? = nil, discovery: AgentCLIDiscovery = ClaudeAgentCLI.defaultDiscovery) {
        self.executableOverride = executableOverride
        self.discovery = discovery
        self.process = AgentCLIProcess(label: Self.toolName)
    }

    static var defaultDiscovery: AgentCLIDiscovery {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AgentCLIDiscovery(candidatePaths: [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.claude/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/usr/bin/claude"
        ])
    }

    func executableURL() -> URL? {
        discovery.resolveExecutable(override: executableOverride)
    }

    var isInstalled: Bool { executableURL() != nil }

    func environment(additional: [String: String] = [:]) -> [String: String] {
        discovery.makeEnvironment(
            removingKeys: Self.subscriptionOverridingKeys,
            adding: additional
        )
    }

    func launch(
        arguments: [String],
        additionalEnvironment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) throws -> AgentCLILaunch {
        guard let executable = executableURL() else {
            throw AgentCLIError.notInstalled(Self.toolName)
        }
        return AgentCLILaunch(
            executable: executable,
            arguments: arguments,
            environment: environment(additional: additionalEnvironment),
            currentDirectory: currentDirectory
        )
    }

    func streamLines(
        arguments: [String],
        additionalEnvironment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        let launch = try launch(
            arguments: arguments,
            additionalEnvironment: additionalEnvironment,
            currentDirectory: currentDirectory
        )
        return process.streamLines(launch)
    }

    func authStatus() async throws -> ClaudeAgentAuthStatus {
        let result = try await process.run(try launch(arguments: ["auth", "status", "--json"]))
        guard result.code == 0 else { return .signedOut }
        return Self.decodeAuthStatus(result.output) ?? .signedOut
    }

    func version() async throws -> String? {
        let result = try await process.run(try launch(arguments: ["--version"]))
        guard result.code == 0 else { return nil }
        return Self.parseVersion(result.output)
    }

    static func decodeAuthStatus(_ output: String) -> ClaudeAgentAuthStatus? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else {
            return nil
        }
        let json = String(output[start ... end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeAgentAuthStatus.self, from: data)
    }

    static func parseVersion(_ output: String) -> String? {
        let scalars = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = scalars.split(separator: " ").first else { return nil }
        let candidate = String(first)
        return candidate.first?.isNumber == true ? candidate : nil
    }

    static func meetsMinimumVersion(_ version: String?) -> Bool {
        guard let version else { return false }
        return AgentCLIDiscovery.compareVersions(version, minimumVersion) != .orderedAscending
    }
}
