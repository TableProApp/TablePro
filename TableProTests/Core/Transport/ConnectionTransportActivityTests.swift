//
//  ConnectionTransportActivityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionTransportActivity")
struct ConnectionTransportActivityTests {
    private let totals = TransportByteTotals(received: 4_096, sent: 1_024)

    @Test("A connection with no transport reads as Direct and carries no figure")
    func directIsNamedAndUnmeasured() {
        let activity = ConnectionTransportActivityResolver.resolve(tunnelKind: nil, totals: totals, rate: .zero)

        #expect(activity.transportName == ConnectionTunnelKind.directDisplayName)
        #expect(activity.totals == nil)
        #expect(!activity.isMeasured)
    }

    @Test("An SSH tunnel carries its totals")
    func sshIsMeasured() {
        let activity = ConnectionTransportActivityResolver.resolve(tunnelKind: .ssh, totals: totals, rate: nil)

        #expect(activity.transportName == ConnectionTunnelKind.ssh.displayName)
        #expect(activity.totals == totals)
        #expect(activity.isMeasured)
    }

    @Test("A SOCKS proxy carries its totals")
    func socksIsMeasured() {
        let activity = ConnectionTransportActivityResolver.resolve(tunnelKind: .socksProxy, totals: totals, rate: nil)

        #expect(activity.totals == totals)
        #expect(activity.isMeasured)
    }

    /// The registry is keyed by connection id, and a connection can be reconfigured from SSH to
    /// Cloudflare without changing that id. Resolving from the kind rather than from whatever the
    /// table happens to hold is what stops the earlier transport's totals being reported as this
    /// one's.
    @Test("A transport the app cannot count shows no figure even when the registry holds one")
    func subprocessTransportsNeverReportTotals() {
        for kind in [ConnectionTunnelKind.cloudflare, .cloudSQLProxy, .tunnelCommand, .remoteFile] {
            let activity = ConnectionTransportActivityResolver.resolve(
                tunnelKind: kind,
                totals: totals,
                rate: TransportRate(receivedPerSecond: 900, sentPerSecond: 100)
            )

            #expect(activity.transportName == kind.displayName)
            #expect(activity.totals == nil)
            #expect(activity.displayedRate == nil)
            #expect(!activity.isMeasured)
        }
    }

    @Test("A measurable transport that has not opened yet shows no figure")
    func measurableButAbsentCounter() {
        let activity = ConnectionTransportActivityResolver.resolve(
            tunnelKind: .ssh,
            totals: nil,
            rate: TransportRate(receivedPerSecond: 900, sentPerSecond: 100)
        )

        #expect(!activity.isMeasured)
        #expect(activity.displayedRate == nil)
    }

    /// "0 B/s" reads as a broken connection rather than a quiet one, and the totals beside it
    /// already carry the honest answer.
    @Test("An idle rate is withheld while the totals stay")
    func idleRateIsWithheld() {
        let activity = ConnectionTransportActivityResolver.resolve(tunnelKind: .ssh, totals: totals, rate: .zero)

        #expect(activity.totals == totals)
        #expect(activity.displayedRate == nil)
    }

    @Test("A moving rate is shown")
    func movingRateIsShown() {
        let rate = TransportRate(receivedPerSecond: 145_408, sentPerSecond: 2)
        let activity = ConnectionTransportActivityResolver.resolve(tunnelKind: .ssh, totals: totals, rate: rate)

        #expect(activity.displayedRate == rate)
    }

    /// Exhaustive on purpose: a transport added without deciding this reports a number it cannot
    /// measure, or hides one it can.
    @Test("Every tunnel kind declares whether its bytes are measured")
    func everyKindDeclaresMeasurability() {
        let measured = ConnectionTunnelKind.allCases.filter(\.carriesMeasuredBytes)

        #expect(Set(measured) == Set([.ssh, .socksProxy]))
    }
}
