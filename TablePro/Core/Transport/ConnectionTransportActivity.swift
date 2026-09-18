//
//  ConnectionTransportActivity.swift
//  TablePro
//

import Foundation

/// Everything the connection activity readout says about one connection, resolved in one place so
/// the view has nothing left to decide.
struct ConnectionTransportActivity: Equatable {
    let transportName: String
    let totals: TransportByteTotals?
    let rate: TransportRate?

    /// Whether a figure exists at all. False both for a transport whose bytes the app never sees
    /// and for a measurable one that has not opened yet, which the readout treats the same way:
    /// it names the transport and shows no number, rather than showing a zero that reads as a
    /// connection carrying nothing.
    var isMeasured: Bool {
        totals != nil
    }

    /// Shown only while something is moving. An idle rate is "0 B/s", which says a connection is
    /// broken rather than quiet, and the totals beside it already carry the honest answer.
    var displayedRate: TransportRate? {
        guard let rate, !rate.isIdle else { return nil }
        return rate
    }
}

enum ConnectionTransportActivityResolver {
    /// A connection whose transport the app cannot count is resolved with `totals` nil whatever the
    /// registry holds, so a stale entry from an earlier transport on the same connection id can
    /// never be attributed to this one.
    static func resolve(
        tunnelKind: ConnectionTunnelKind?,
        totals: TransportByteTotals?,
        rate: TransportRate?
    ) -> ConnectionTransportActivity {
        guard let tunnelKind else {
            return ConnectionTransportActivity(
                transportName: ConnectionTunnelKind.directDisplayName,
                totals: nil,
                rate: nil
            )
        }
        guard tunnelKind.carriesMeasuredBytes else {
            return ConnectionTransportActivity(transportName: tunnelKind.displayName, totals: nil, rate: nil)
        }
        return ConnectionTransportActivity(
            transportName: tunnelKind.displayName,
            totals: totals,
            rate: totals == nil ? nil : rate
        )
    }
}
