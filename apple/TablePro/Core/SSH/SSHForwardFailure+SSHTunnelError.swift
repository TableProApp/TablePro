import Foundation

import TableProSSHTransport

extension SSHForwardFailure {
    var tunnelError: SSHTunnelError {
        switch self {
        case .refused(let destination, let detail):
            if case .unixSocket(let path) = destination {
                return .socketForwardingRefused(path: path, detail: detail)
            }
            return .forwardRefused(destination: destination.logDescription, detail: detail)
        case .timedOut(let destination, let seconds):
            return .forwardTimedOut(destination: destination.logDescription, seconds: seconds)
        }
    }
}
