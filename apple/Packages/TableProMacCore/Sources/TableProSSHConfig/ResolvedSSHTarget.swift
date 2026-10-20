//
//  ResolvedSSHTarget.swift
//  TablePro
//

import Foundation

/// Where the agent socket a connection will use came from. `agentSocketPath` collapses three
/// sources into one string, and each is changed somewhere different, so an agent that does not
/// answer can only be reported usefully alongside the source that named it.
public enum AgentSocketOrigin: Sendable, Hashable, CaseIterable {
    /// The Agent Socket control on the SSH Tunnel pane.
    case agentSocketSetting
    /// An `IdentityAgent` directive matching this host in `~/.ssh/config`.
    case identityAgentDirective
    /// `SSH_AUTH_SOCK`, from the process environment or launchd.
    case environment
}

public struct ResolvedSSHTarget: Sendable, Hashable {
    public let originalHost: String
    public let host: String
    public let port: Int
    public let username: String
    public let identityFiles: [String]
    public let agentSocketPath: String
    public let agentSocketOrigin: AgentSocketOrigin
    // `IdentityAgent none`: ssh signs in without an agent.
    public let agentDisabled: Bool
    public let identitiesOnly: Bool
    public let useKeychain: Bool
    public let addKeysToAgent: Bool
    public let proxyJump: [SSHJumpHost]
    /// The first `~/.ssh/config` value whose tokens could not be expanded. Resolution keeps going
    /// so the rest of the target is still built, and the connect path reports this instead of
    /// dialling whatever half-resolved string came out. It defaults to nil because most callers,
    /// the tests included, build a target that never went through expansion.
    public var expansionFailure: SSHTokenExpansionError?

    public init(
        originalHost: String,
        host: String,
        port: Int,
        username: String,
        identityFiles: [String],
        agentSocketPath: String,
        agentSocketOrigin: AgentSocketOrigin,
        agentDisabled: Bool = false,
        identitiesOnly: Bool,
        useKeychain: Bool,
        addKeysToAgent: Bool,
        proxyJump: [SSHJumpHost],
        expansionFailure: SSHTokenExpansionError? = nil
    ) {
        self.originalHost = originalHost
        self.host = host
        self.port = port
        self.username = username
        self.identityFiles = identityFiles
        self.agentSocketPath = agentSocketPath
        self.agentSocketOrigin = agentSocketOrigin
        self.agentDisabled = agentDisabled
        self.identitiesOnly = identitiesOnly
        self.useKeychain = useKeychain
        self.addKeysToAgent = addKeysToAgent
        self.proxyJump = proxyJump
        self.expansionFailure = expansionFailure
    }
}
