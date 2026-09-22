import Foundation

/// Why an Oracle channel was closed from this side.
///
/// OracleNIO reports a client-side close to whatever statement was on the wire as
/// `clientClosedConnection`, and that error names neither the closer nor its reason. A report of
/// one is otherwise only as good as the reader's guess at which of these fired (#3053), so every
/// close says which it is and the log carries it.
public enum OracleDisconnectReason: Sendable, Equatable {
    case userRequested
    case queryCancelled
    case queryTimedOut
    case pingTimedOut
    case wedgedStatement
    case channelAlreadyClosed
    case fatalProtocolError
    case transportError
    case abandonedLoginAttempt

    /// Whether a statement the close killed may be sent again on a replacement connection.
    ///
    /// A deliberate teardown must never be replayed across. The plugin nils its connection on
    /// `disconnect()` and the app removes the session, so a retry would open a socket nobody owns,
    /// report a stale schema switch as having succeeded, and leave that session holding none of the
    /// state the caller thinks it has. Everything else here took the channel away from a session
    /// that is still wanted.
    public var allowsReplay: Bool {
        switch self {
        case .userRequested, .queryCancelled, .abandonedLoginAttempt:
            return false
        case .queryTimedOut, .pingTimedOut, .wedgedStatement, .channelAlreadyClosed,
             .fatalProtocolError, .transportError:
            return true
        }
    }

    public var logDescription: String {
        switch self {
        case .userRequested: return "the app closed it"
        case .queryCancelled: return "the query was cancelled"
        case .queryTimedOut: return "the query timeout fired"
        case .pingTimedOut: return "the health check got no answer"
        case .wedgedStatement: return "a statement held it past the staleness limit"
        case .channelAlreadyClosed: return "OracleNIO had already closed the channel"
        case .fatalProtocolError: return "the server sent an unexpected message"
        case .transportError: return "the transport failed"
        case .abandonedLoginAttempt: return "the login attempt had already been given up on"
        }
    }
}
