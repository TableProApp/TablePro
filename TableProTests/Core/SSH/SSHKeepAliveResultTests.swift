//
//  SSHKeepAliveResultTests.swift
//  TableProTests
//
//  The keep-alive runs against a non-blocking session, so libssh2 can answer EAGAIN when the
//  transport is busy. Treating that as fatal marked a healthy tunnel dead and dropped every
//  connection through it.
//

import CLibSSH2
@testable import TablePro
import Testing

@Suite("sshKeepAliveDidFail")
struct SSHKeepAliveResultTests {
    @Test("A sent keep-alive is not a failure")
    func successIsNotFailure() {
        #expect(sshKeepAliveDidFail(0) == false)
    }

    @Test("A keep-alive that would block is not a failure")
    func wouldBlockIsNotFailure() {
        #expect(sshKeepAliveDidFail(LIBSSH2_ERROR_EAGAIN) == false)
    }

    @Test("A send error is a failure")
    func sendErrorIsFailure() {
        #expect(sshKeepAliveDidFail(LIBSSH2_ERROR_SOCKET_SEND))
    }

    @Test("Any other libssh2 error is a failure")
    func otherErrorsAreFailures() {
        #expect(sshKeepAliveDidFail(-1))
        #expect(sshKeepAliveDidFail(LIBSSH2_ERROR_SOCKET_DISCONNECT))
    }
}
