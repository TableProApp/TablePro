//
//  SSHForwardChannelOpenPump.swift
//  TablePro
//

import Foundation

internal enum ChannelOpenOutcome: Equatable {
    case opened(OpaquePointer)
    case failed(code: Int32, message: String)
    case timedOut
    case cancelled
}

internal extension ChannelOpenOutcome {
    /// The SSH-layer reason this open failed, ready to surface in place of the database
    /// driver's own error. A driver that dials the local port sees only an accepted socket
    /// that went silent, so its error names a timeout and never the cause.
    func tunnelError(destination: SSHForwardDestination, deadlineSeconds: Int) -> SSHTunnelError? {
        switch self {
        case .opened, .cancelled:
            return nil
        case .failed(_, let message):
            if case .unixSocket(let path) = destination {
                return .socketForwardingRefused(path: path, detail: message)
            }
            return .forwardRefused(destination: destination.logDescription, detail: message)
        case .timedOut:
            return .forwardTimedOut(destination: destination.logDescription, seconds: deadlineSeconds)
        }
    }
}

/// Drives a forwarding channel open to a decision within an app-owned deadline.
///
/// libssh2 signals "not ready yet" with `LIBSSH2_ERROR_EAGAIN` and never gives up on its
/// own, so without a deadline an open can outlive the database driver's own timeout. The
/// driver then sits on an accepted socket that is never written to and never closed, which
/// surfaces as a greeting-read timeout with no indication of the cause. Bounding the open
/// here lets the caller close the socket and name the reason instead.
internal struct SSHForwardChannelOpenPump {
    let opener: any SSHForwardChannelOpening
    let isActive: () -> Bool
    let deadline: Date
    let pollForReadiness: (RelayDirections) -> Bool
    var now: () -> Date = Date.init

    func run() -> ChannelOpenOutcome {
        while true {
            guard isActive() else { return .cancelled }
            guard now() < deadline else { return .timedOut }

            switch opener.attemptOpen() {
            case .opened(let channel):
                return .opened(channel)
            case .failed(let errorCode, let message):
                return .failed(code: errorCode, message: message)
            case .wouldBlock(let directions):
                guard pollForReadiness(directions) else { return .timedOut }
            }
        }
    }
}

/// Hands an opened channel to the relay, and closes the local socket on every other
/// outcome so the client fails fast instead of waiting out its own read timeout on a
/// socket nothing will ever write to.
internal func handleChannelOpenOutcome(
    _ outcome: ChannelOpenOutcome,
    clientFD: Int32,
    onOpened: (OpaquePointer) -> Void
) {
    switch outcome {
    case .opened(let channel):
        onOpened(channel)
    case .failed, .timedOut, .cancelled:
        Darwin.close(clientFD)
    }
}
