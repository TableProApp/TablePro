//
//  SSHForwardChannelOpenPump.swift
//  TableProSSHTransport
//

import Foundation

public enum ChannelOpenOutcome: Equatable {
    case opened(OpaquePointer)
    case failed(code: Int32, message: String)
    case timedOut
    case cancelled
}

public extension ChannelOpenOutcome {
    /// The SSH-layer reason this open failed, ready to surface in place of the database
    /// driver's own error. A driver that dials the local port sees only an accepted socket
    /// that went silent, so its error names a timeout and never the cause.
    func forwardFailure(destination: SSHForwardDestination, deadlineSeconds: Int) -> SSHForwardFailure? {
        switch self {
        case .opened, .cancelled:
            return nil
        case .failed(_, let message):
            return .refused(destination: destination, detail: message)
        case .timedOut:
            return .timedOut(destination: destination, seconds: deadlineSeconds)
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
public struct SSHForwardChannelOpenPump {
    public let opener: any SSHForwardChannelOpening
    public let isActive: () -> Bool
    public let deadline: Date
    public let pollForReadiness: (RelayDirections) -> Bool
    public var now: () -> Date

    public init(
        opener: any SSHForwardChannelOpening,
        isActive: @escaping () -> Bool,
        deadline: Date,
        pollForReadiness: @escaping (RelayDirections) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.opener = opener
        self.isActive = isActive
        self.deadline = deadline
        self.pollForReadiness = pollForReadiness
        self.now = now
    }

    public func run() -> ChannelOpenOutcome {
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
public func handleChannelOpenOutcome(
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
