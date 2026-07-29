//
//  SSHKeepAliveResultTests.swift
//  TableProTests
//
//  The keep-alive runs against a non-blocking session, so libssh2 can answer EAGAIN when the
//  transport is busy. Treating that as fatal marked a healthy tunnel dead and dropped every
//  connection through it.
//

@testable import TablePro
import Testing

@Suite("sshKeepAliveDidFail")
struct SSHKeepAliveResultTests {
    @Test("A sent keep-alive is not a failure")
    func successIsNotFailure() {
        #expect(sshKeepAliveDidFail(SSHKeepAliveCode.sent) == false)
    }

    @Test("A keep-alive that would block is not a failure")
    func wouldBlockIsNotFailure() {
        #expect(sshKeepAliveDidFail(SSHKeepAliveCode.wouldBlock) == false)
    }

    @Test("A send error is a failure")
    func sendErrorIsFailure() {
        #expect(sshKeepAliveDidFail(SSHKeepAliveCode.socketSend))
    }

    @Test("A disconnected socket is a failure")
    func disconnectIsFailure() {
        #expect(sshKeepAliveDidFail(SSHKeepAliveCode.socketDisconnect))
    }

    @Test("Would-block is a distinct code, not an alias for success")
    func wouldBlockIsNotSuccess() {
        #expect(SSHKeepAliveCode.wouldBlock != SSHKeepAliveCode.sent)
    }

    @Test("Any other libssh2 error is a failure")
    func otherErrorsAreFailures() {
        #expect(sshKeepAliveDidFail(-1))
    }
}
