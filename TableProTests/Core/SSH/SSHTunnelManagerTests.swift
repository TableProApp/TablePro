//
//  SSHTunnelManagerTests.swift
//  TableProTests
//
//  Tests for SSH tunnel port binding safeguards.
//

@testable import TablePro
import Testing

@Suite("SSHTunnelManager")
struct SSHTunnelManagerTests {
    @Test("Ownership checks include child ssh processes")
    func descendantProcessIdsIncludeChildren() {
        let processTree = SSHTunnelManager.descendantProcessIds(
            rootProcessId: 100,
            parentProcessIds: [
                101: 100,
                102: 101,
                200: 999,
            ]
        )

        #expect(processTree == [100, 101, 102])
    }

    @Test("Local port bind failures are treated as retryable")
    func localPortBindFailuresAreRetryable() {
        let errorMessage = """
        bind [127.0.0.1]:60000: Address already in use
        channel_setup_fwd_listener_tcpip: cannot listen to port: 60000
        Could not request local forwarding.
        """

        #expect(SSHTunnelManager.isLocalPortBindFailure(errorMessage))
    }

    @Test("Non-bind SSH failures are not retried as port races")
    func nonBindFailuresAreNotRetried() {
        #expect(SSHTunnelManager.isLocalPortBindFailure("Permission denied (publickey,password).") == false)
        #expect(SSHTunnelManager.isLocalPortBindFailure("Connection timed out during banner exchange") == false)
    }

    @Test("Generic forwarding failures are treated as retryable bind failures")
    func genericForwardingFailuresAreRetryable() {
        let errorMessage = "Error: port forwarding failed for listen port 60123"
        #expect(SSHTunnelManager.isLocalPortBindFailure(errorMessage))
    }
}
