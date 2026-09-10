//
//  ResolvedSSHTarget.swift
//  TablePro
//

import Foundation

/// Where the agent socket a connection will use came from. `agentSocketPath` collapses three
/// sources into one string, and each is changed somewhere different, so an agent that does not
/// answer can only be reported usefully alongside the source that named it.
enum AgentSocketOrigin: Sendable, Hashable, CaseIterable {
    /// The Agent Socket control on the SSH Tunnel pane.
    case agentSocketSetting
    /// An `IdentityAgent` directive matching this host in `~/.ssh/config`.
    case identityAgentDirective
    /// `SSH_AUTH_SOCK`, from the process environment or launchd.
    case environment
}

struct ResolvedSSHTarget: Sendable, Hashable {
    let originalHost: String
    let host: String
    let port: Int
    let username: String
    let identityFiles: [String]
    let agentSocketPath: String
    let agentSocketOrigin: AgentSocketOrigin
    let identitiesOnly: Bool
    let useKeychain: Bool
    let addKeysToAgent: Bool
    let proxyJump: [SSHJumpHost]
    /// The first `~/.ssh/config` value whose tokens could not be expanded. Resolution keeps going
    /// so the rest of the target is still built, and the connect path reports this instead of
    /// dialling whatever half-resolved string came out. It defaults to nil because most callers,
    /// the tests included, build a target that never went through expansion.
    var expansionFailure: SSHTokenExpansionError?

    init(
        originalHost: String,
        host: String,
        port: Int,
        username: String,
        identityFiles: [String],
        agentSocketPath: String,
        agentSocketOrigin: AgentSocketOrigin,
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
        self.identitiesOnly = identitiesOnly
        self.useKeychain = useKeychain
        self.addKeysToAgent = addKeysToAgent
        self.proxyJump = proxyJump
        self.expansionFailure = expansionFailure
    }
}
