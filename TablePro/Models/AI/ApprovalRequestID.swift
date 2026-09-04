//
//  ApprovalRequestID.swift
//  TablePro
//

import Foundation

/// What `ToolApprovalCenter` keys a pending approval by.
///
/// The provider's own tool-use string is not enough on its own. Self-hosted and proxied endpoints
/// emit `call_0`, `call_1`, so two sessions streaming at once collide: the center used to key by
/// that string alone, and a decision made in one session resumed the other session's continuation.
/// Pairing it with the session that asked makes the key unique without inventing a second
/// identifier the model would then have to be told about, and the provider's string stays exactly
/// what it was, because it is what correlates the tool result back to the model.
internal struct ApprovalRequestID: Hashable, Sendable {
    internal let sessionId: UUID
    internal let toolUseId: String
}
