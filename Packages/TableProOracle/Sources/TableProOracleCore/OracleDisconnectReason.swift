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
