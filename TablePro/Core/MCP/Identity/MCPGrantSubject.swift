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
enum MCPGrantSubject: Sendable, Equatable {
    case bridge
    case token(UUID)

    var storageKey: String {
        switch self {
        case .bridge: return "bridge"
        case .token(let id): return id.uuidString
        }
    }
}

extension MCPPrincipal {
    /// The subject a durable grant belongs to, or nil when this caller may not earn one.
    ///
    /// An anonymous loopback caller collapses to a single shared identity with nothing to
    /// distinguish one local process from the next, so remembering its answer would silently
    /// approve every future unauthenticated caller. It keeps the session-only approval it has today.
    var grantSubject: MCPGrantSubject? {
        if metadata.isBridgeCredential { return .bridge }
        guard let tokenId else { return nil }
        return .token(tokenId)
    }
}
