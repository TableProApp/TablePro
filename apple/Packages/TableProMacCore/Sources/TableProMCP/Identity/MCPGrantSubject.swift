import Foundation

/// The identity a remembered MCP approval is filed under.
///
/// Deliberately not `MCPPrincipal.ledgerKey`. The bundled stdio bridge re-mints its credential with
/// a fresh UUID roughly every 45 minutes and deletes the previous one, and that delete notifies the
/// revocation observers, so a grant filed under the token id is both orphaned and actively revoked
/// before the hour is out. The bridge is one client however often its credential turns over.
///
/// The bridge is recognised by a flag its own mint sets on the token record, never by the token's
/// name: a pairing request carries the client name it wants, so a name test would let any caller
/// ask to be the bridge and inherit every grant the bridge had earned.
public enum MCPGrantSubject: Sendable, Equatable {
    case bridge
    // The Claude Agent chat mints a token for every turn and deletes it after, the way the bridge rotates.
    case claudeAgent
    case token(UUID)

    public init(tokenId: UUID, isBridgeCredential: Bool, isClaudeAgentCredential: Bool) {
        if isBridgeCredential {
            self = .bridge
        } else if isClaudeAgentCredential {
            self = .claudeAgent
        } else {
            self = .token(tokenId)
        }
    }

    public var storageKey: String {
        switch self {
        case .bridge: return "bridge"
        case .claudeAgent: return "claude-agent"
        case .token(let id): return id.uuidString
        }
    }
}

public extension MCPPrincipal {
    var grantSubject: MCPGrantSubject {
        MCPGrantSubject(
            tokenId: tokenId,
            isBridgeCredential: metadata.isBridgeCredential,
            isClaudeAgentCredential: metadata.isClaudeAgentCredential
        )
    }
}
