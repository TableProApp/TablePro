//
//  SSHKeepAliveResult.swift
//  TablePro
//

import CLibSSH2

/// Whether a keep-alive return code means the tunnel is dead. The session is non-blocking for
/// the whole time it forwards, so libssh2 answers `LIBSSH2_ERROR_EAGAIN` when the send would
/// block on a transport that is busy carrying query results. That is a healthy tunnel under
/// load, not a dead one, and tearing it down drops every connection running through it.
internal func sshKeepAliveDidFail(_ resultCode: Int32) -> Bool {
    resultCode != 0 && resultCode != LIBSSH2_ERROR_EAGAIN
}
