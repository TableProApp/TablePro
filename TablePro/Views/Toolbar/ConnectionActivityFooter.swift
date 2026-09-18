//
//  ConnectionActivityFooter.swift
//  TablePro
//

import SwiftUI

/// What the connection the window is on is carrying, under the list of connections it could switch
/// to. Totals first with the rate parenthetical beside the direction it belongs to, which is the
/// shape Safari's downloads popover uses: a total stays true whatever the sampling interval is, and
/// a rate that is only shown while something moves never reads as a broken connection.
///
/// The sampling runs on this view's own `task`, so nothing computes a rate while the popover is
/// closed. The counters underneath keep running, but they are one increment on a byte count the
/// transport already had in hand.
struct ConnectionActivityFooter: View {
    let connection: DatabaseConnection?

    @State private var sampler = TransportRateSampler()
    @State private var activity: ConnectionTransportActivity?

    private static let sampleInterval = Duration.seconds(1)

    /// The sampling task hangs off an `if`/`else`, never a `Group`: a modifier on a `Group` is
    /// applied to each of its children, so an empty one carries the task nowhere and the first
    /// reading is never taken.
    var body: some View {
        content
            .task(id: connection?.id) {
                await sampleUntilCancelled()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let activity {
            row(activity)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private func row(_ activity: ConnectionTransportActivity) -> some View {
        HStack(spacing: 8) {
            Text(activity.transportName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("connection-activity-transport")

            Spacer(minLength: 8)

            if let totals = activity.totals {
                direction(
                    symbol: "arrow.down",
                    label: String(localized: "Received"),
                    bytes: totals.received,
                    bytesPerSecond: activity.displayedRate?.receivedPerSecond
                )
                direction(
                    symbol: "arrow.up",
                    label: String(localized: "Sent"),
                    bytes: totals.sent,
                    bytesPerSecond: activity.displayedRate?.sentPerSecond
                )
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .help(helpText(activity))
    }

    /// Tabular figures, so a rate that changes every second does not shuffle the text beside it.
    /// Postico shipped that same fix for its elapsed-time readout.
    private func direction(symbol: String, label: String, bytes: UInt64, bytesPerSecond: Double?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .accessibilityLabel(label)

            Text(ByteSizeFormatting.string(bytes: bytes))

            if let bytesPerSecond {
                Text(ByteSizeFormatting.string(bytesPerSecond: bytesPerSecond))
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    private func helpText(_ activity: ConnectionTransportActivity) -> String {
        guard activity.isMeasured else {
            return String(localized: "Throughput is measured for SSH tunnels and SOCKS proxies, the transports TablePro carries the bytes for itself.")
        }
        return String(localized: "Bytes carried since the transport opened.")
    }

    private func sampleUntilCancelled() async {
        guard let connection else {
            activity = nil
            return
        }

        sampler = TransportRateSampler()
        publish(resolve(connection, totals: totals(of: connection), rate: nil))

        /// A transport whose bytes the app never sees has one reading and no second one to take,
        /// so the loop would wake every second to resolve the same row forever.
        guard connection.activeTunnelKind?.carriesMeasuredBytes == true else { return }

        while !Task.isCancelled {
            try? await Task.sleep(for: Self.sampleInterval)
            guard !Task.isCancelled else { return }

            let totals = totals(of: connection)
            let rate = totals.flatMap { sampler.sample($0, at: .now) }
            publish(resolve(connection, totals: totals, rate: rate))
        }
    }

    /// An idle transport resolves to the same row every second, and writing it back rebuilds the
    /// footer each time for no change on screen.
    private func publish(_ next: ConnectionTransportActivity) {
        guard next != activity else { return }
        activity = next
    }

    private func totals(of connection: DatabaseConnection) -> TransportByteTotals? {
        TransportActivityRegistry.shared.totals(for: connection.id)
    }

    private func resolve(
        _ connection: DatabaseConnection,
        totals: TransportByteTotals?,
        rate: TransportRate?
    ) -> ConnectionTransportActivity {
        ConnectionTransportActivityResolver.resolve(
            tunnelKind: connection.activeTunnelKind,
            totals: totals,
            rate: rate
        )
    }
}
