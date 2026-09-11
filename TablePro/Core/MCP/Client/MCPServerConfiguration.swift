//
//  MCPServerConfiguration.swift
//  TablePro
//

import Foundation

/// An outside MCP server a session may call, and which connections may call it.
///
/// HTTP only. The transport is already in production inside the `tablepro-mcp` bridge, so this
/// direction reuses it rather than introducing a second one; a stdio server would mean owning a
/// child process, and a child process that outlives its session is the failure this deliberately
/// does not risk yet.
internal struct MCPServerConfiguration: Codable, Equatable, Identifiable, Sendable {
    /// The namespace prefix is keyed on this id, not on `name`. `ClaudeAgentProvider` launches the
    /// CLI with `--allowedTools mcp__tablepro__*`, so a user-supplied name that slugified to
    /// `tablepro` would land a remote tool inside a pre-approved wildcard and run it with no card.
    internal let id: UUID
    internal var name: String
    internal var endpoint: URL

    /// Which connections a session may reach this server from. Empty means none: a server added and
    /// not yet allowed anywhere is inert, which is the safe reading of a half-finished setup.
    internal var allowedConnectionIds: Set<UUID>

    internal init(
        id: UUID = UUID(),
        name: String,
        endpoint: URL,
        allowedConnectionIds: Set<UUID> = []
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.allowedConnectionIds = allowedConnectionIds
    }

    /// The prefix every one of this server's tools carries.
    internal var toolNamespace: String { "ext__\(id.uuidString.lowercased())__" }

    internal func toolName(for remoteName: String) -> String { toolNamespace + remoteName }

    internal func allows(connectionId: UUID?) -> Bool {
        guard let connectionId else { return false }
        return allowedConnectionIds.contains(connectionId)
    }
}

/// Why a configuration was refused. Reported rather than silently corrected, because every one of
/// these is a decision the user has to make differently.
internal enum MCPServerConfigurationError: Error, Equatable, Sendable {
    case emptyName
    case reservedName
    case invalidEndpoint
    case insecureEndpoint
}

internal enum MCPServerConfigurationValidator {
    /// Names that would collide with TablePro's own MCP namespace.
    internal static let reservedSlugs: Set<String> = ["tablepro", "table-pro", "table_pro"]

    /// Slugified the way a namespace would be, so `TablePro`, `Table Pro` and `table-pro` are all
    /// caught rather than only the exact string.
    internal static func slug(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// A non-loopback endpoint has to be HTTPS. Plain HTTP to another machine puts the schema and
    /// the results the assistant hands the server on the wire in the clear; loopback is exempt
    /// because it never reaches one.
    internal static func validate(name: String, endpoint: URL?) -> MCPServerConfigurationError? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .emptyName }
        if reservedSlugs.contains(slug(trimmed)) { return .reservedName }
        guard let endpoint, let scheme = endpoint.scheme?.lowercased(), endpoint.host != nil else {
            return .invalidEndpoint
        }
        guard scheme == "http" || scheme == "https" else { return .invalidEndpoint }
        if scheme == "http", !Self.isLoopback(endpoint) { return .insecureEndpoint }
        return nil
    }

    private static func isLoopback(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}
