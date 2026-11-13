//
//  SSHKeepAliveResult.swift
//  TablePro
//
//  Compiled into the macOS app and, by file reference, into the iOS app, which defaults to
//  MainActor isolation. Every top-level declaration states its own isolation for that reason;
//  the iOS build is the check.
//

import Foundation

import CLibSSH2
import TableProSSHTransport

// The libssh2 return codes the keep-alive has to tell apart, named here so callers and tests
// can work with them without pulling the C module in.
nonisolated internal enum SSHKeepAliveCode {
    static let sent: Int32 = 0
    static let wouldBlock: Int32 = LIBSSH2_ERROR_EAGAIN
    static let socketSend: Int32 = LIBSSH2_ERROR_SOCKET_SEND
    static let socketDisconnect: Int32 = LIBSSH2_ERROR_SOCKET_DISCONNECT
}

// Whether a keep-alive return code means the tunnel is dead. The session is non-blocking for
// the whole time it forwards, so libssh2 answers `LIBSSH2_ERROR_EAGAIN` when the send would
// block on a transport that is busy carrying query results. That is a healthy tunnel under
// load, not a dead one, and tearing it down drops every connection running through it.
nonisolated internal func sshKeepAliveDidFail(_ resultCode: Int32) -> Bool {
    resultCode != SSHKeepAliveCode.sent && resultCode != SSHKeepAliveCode.wouldBlock
}

nonisolated internal struct SSHKeepAliveOutcome: Sendable {
    let failed: Bool
    let secondsToNext: Int
}

nonisolated internal enum StackPacketReadiness {
    case ready
    case socketFull
    case sendPending
    case gone
}

// libssh2 keeps a packet it could not send whole until a call with the same buffer address sends the rest, and
// turns every other send away until then (transport_send_existing). The keep-alive and the channel EOF build
// their packets on their own stack, and a retry from another frame cannot finish them, so one that blocks stops
// every channel on the session (apple/scripts/probes/check-libssh2-keepalive-pending.sh). Such a packet goes out
// only when nothing else is waiting to send and the socket has room for it whole.
nonisolated internal func stackPacketReadiness(session: OpaquePointer, transportFD: Int32) -> StackPacketReadiness {
    switch transportRoom(transportFD) {
    case .gone:
        return .gone
    case .full:
        return .socketFull
    case .room:
        let pending = libssh2_session_block_directions(session) & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0
        return pending ? .sendPending : .ready
    }
}

nonisolated internal enum LibSSH2KeepAlive {
    // Without a reply asked for: libssh2 never reads one, and each REQUEST_FAILURE sshd sends back stays at the
    // head of the session's packet list for good (channel.c, ssh2_channel_read skips it without unlinking it).
    static let wantsReply: Int32 = 0
    static let intervalSeconds: UInt32 = 30

    private static let retrySeconds = 1

    static func configure(session: OpaquePointer) {
        libssh2_keepalive_config(session, wantsReply, intervalSeconds)
    }

    // libssh2 sends at most once per interval and answers how long until the next one is due.
    static func send(session: OpaquePointer, transportFD: Int32) -> SSHKeepAliveOutcome {
        switch stackPacketReadiness(session: session, transportFD: transportFD) {
        case .gone:
            return SSHKeepAliveOutcome(failed: true, secondsToNext: retrySeconds)
        case .socketFull, .sendPending:
            return SSHKeepAliveOutcome(failed: false, secondsToNext: retrySeconds)
        case .ready:
            var secondsToNext: Int32 = 0
            let resultCode = libssh2_keepalive_send(session, &secondsToNext)
            return SSHKeepAliveOutcome(failed: sshKeepAliveDidFail(resultCode), secondsToNext: max(1, Int(secondsToNext)))
        }
    }
}
