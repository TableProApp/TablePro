import Foundation

// Each app builds the error the user reads from this, since each spells its own SSHTunnelError.
// The destination travels with the reason because a refused unix socket and a refused TCP port
// send the user to different settings on the server.
public enum SSHForwardFailure: Equatable, Sendable {
    case refused(destination: SSHForwardDestination, detail: String)
    case timedOut(destination: SSHForwardDestination, seconds: Int)
}
