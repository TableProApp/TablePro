//
//  SSHTunnelDeadlineMarginTests.swift
//  TableProTests
//
//  Guards the margin that lets the tunnel name a forwarding failure before the database
//  driver reports its own timeout. The previous budget matched the driver's 10 seconds
//  exactly, and since the driver's clock starts when it dials while the tunnel's starts
//  only once the accept is noticed, the tunnel could never win and the user saw an errno
//  that names no cause (#1981, recurrence of #1883).
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSH tunnel deadline margin")
struct SSHTunnelDeadlineMarginTests {
    /// Every bundled driver hardcodes a 10 second connect timeout.
    private static let driverConnectTimeoutSeconds: TimeInterval = 10

    @Test("The channel-open budget stays under every bundled driver's connect timeout")
    func channelOpenBudgetStaysUnderDriverTimeout() {
        #expect(LibSSH2Tunnel.channelOpenDeadlineSeconds < Self.driverConnectTimeoutSeconds)
    }

    @Test("The margin is wide enough to absorb the accept poll and the scheduling hops")
    func marginAbsorbsAcceptLatency() {
        let margin = Self.driverConnectTimeoutSeconds - LibSSH2Tunnel.channelOpenDeadlineSeconds
        let acceptPollSeconds = TimeInterval(LibSSH2Tunnel.acceptPollTimeoutMs) / 1_000

        #expect(margin >= 2)
        #expect(margin > acceptPollSeconds)
    }

    @Test("The accept loop notices a waiting client well inside the margin")
    func acceptPollIsShort() {
        #expect(LibSSH2Tunnel.acceptPollTimeoutMs <= 200)
        #expect(LibSSH2Tunnel.acceptPollTimeoutMs > 0)
    }
}
