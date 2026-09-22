import Foundation

/// What is known about the last time this connection's channel went away, and whether the
/// connection is finished for good.
///
/// Two closers reach one channel: whoever decided to close it, and the statement that was on the
/// wire when it went. The second one arrives through OracleNIO as `clientClosedConnection` and
/// knows nothing about the first, so it must not be allowed to overwrite what the first recorded.
/// Letting it did exactly that: a user disconnect recorded "the app closed it", the dying
/// statement replaced it with "OracleNIO had already closed the channel", and the replay guard
/// then read a reason that permits a redial.
///
/// `isFinished` is deliberately one-way. The plugin drops its `OracleCoreConnection` when the app
/// disconnects and builds a new one to reconnect, so a connection closed that way is never reached
/// again by anything the app owns, and anything still holding it has to find it finished.
internal struct OracleCloseRecord: Sendable, Equatable {
    private(set) var reason: OracleDisconnectReason?
    private(set) var isFinished = false

    mutating func record(_ reason: OracleDisconnectReason) {
        isFinished = isFinished || reason.endsConnection
        guard self.reason == nil else { return }
        self.reason = reason
    }

    mutating func clearOnConnect() {
        reason = nil
    }

    /// Whether a statement that only configures the session may be sent again on a replacement
    /// connection.
    var allowsSessionSetupReplay: Bool {
        !isFinished && reason?.allowsReplay == true
    }

    /// Whether a statement that finds no channel may open one.
    var allowsReconnect: Bool {
        !isFinished
    }
}
