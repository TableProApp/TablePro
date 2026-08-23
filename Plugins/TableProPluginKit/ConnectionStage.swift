import Foundation

/// A step a connection attempt passes through, reported as it starts so a window can say what
/// it is waiting on instead of showing an unexplained spinner.
///
/// Left non-frozen so it can gain steps without an ABI bump, and `custom` carries an
/// engine-specific step that does not earn a shared case.
public enum ConnectionStage: Sendable, Equatable {
    case resolvingTunnel
    case runningPreConnectScript
    case awaitingCredentials
    case openingConnection
    case negotiatingEncryption
    case authenticating
    case preparingSession
    case custom(String)
}

/// Called on whatever thread the stage is observed from, so it must be cheap and must not
/// assume the main actor. It is deliberately synchronous: the deepest call sites are C poll
/// loops where a suspension point would change the timing of the connect itself.
public typealias ConnectionStageReporter = @Sendable (ConnectionStage) -> Void
