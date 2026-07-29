//
//  SSHKeepAliveResult.swift
//  TablePro
//

import CLibSSH2

/// The libssh2 return codes the keep-alive has to tell apart, named here so callers and tests
/// can work with them without pulling the C module in.
internal enum SSHKeepAliveCode {
    static let sent: Int32 = 0
    static let wouldBlock: Int32 = LIBSSH2_ERROR_EAGAIN
    static let socketSend: Int32 = LIBSSH2_ERROR_SOCKET_SEND
    static let socketDisconnect: Int32 = LIBSSH2_ERROR_SOCKET_DISCONNECT
}

/// Whether a keep-alive return code means the tunnel is dead. The session is non-blocking for
/// the whole time it forwards, so libssh2 answers `LIBSSH2_ERROR_EAGAIN` when the send would
/// block on a transport that is busy carrying query results. That is a healthy tunnel under
/// load, not a dead one, and tearing it down drops every connection running through it.
internal func sshKeepAliveDidFail(_ resultCode: Int32) -> Bool {
    resultCode != SSHKeepAliveCode.sent && resultCode != SSHKeepAliveCode.wouldBlock
}
