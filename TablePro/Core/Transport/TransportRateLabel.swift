//
//  TransportRateLabel.swift
//  TablePro
//

import Foundation

/// The throughput as one short line: an arrow for the busier direction and a figure.
///
/// Only one direction is shown. Two rates side by side is more width than the centred toolbar item
/// has, and for a database connection the interesting one is whichever is moving: results coming
/// back, or an import going out.
///
/// The figure is assembled from a number and a unit rather than handed to `.byteCount`, which
/// cannot produce a shape that holds a constant width. Measured: `allowedUnits: [.kb]` floors
/// nothing, so 512 still comes back "512 bytes", and zero comes back "Zero kB" whatever the units
/// say. Both are four characters wider than the figures around them. The unit is left unlocalized,
/// per the rule that technical terms are; the figure is localized.
///
/// An idle transport reads `0 kB/s` rather than going blank. Worth knowing before reading much into
/// that figure: polling TablePlus's equivalent readout over an SSH tunnel gave `0 B/s` in 19 of 20
/// idle samples, and in 37 of 45 taken during two table reloads. A quiet connection is the normal
/// case, not a broken one.
internal enum TransportRateLabel {
    /// Every shape the label can take, which is what the toolbar's field measures itself against so
    /// its width is settled once and never follows the figure.
    internal static let widestCandidates = ["\u{2193}999 kB/s", "\u{2193}999 MB/s", "\u{2193}999 GB/s"]

    private static let bytesPerKilobyte: Double = 1_000

    internal static func text(for rate: TransportRate?) -> String {
        arrow(for: rate) + figureAndUnit(for: rate)
    }

    private static func figureAndUnit(for rate: TransportRate?) -> String {
        let value = rate.map { max($0.receivedPerSecond, $0.sentPerSecond) } ?? 0
        guard value.isFinite, value > 0 else { return figure(0) + " kB/s" }

        let kilobytes = value / bytesPerKilobyte
        guard kilobytes >= 1 else { return figure(0) + " kB/s" }
        guard kilobytes >= bytesPerKilobyte else { return figure(kilobytes) + " kB/s" }

        let megabytes = kilobytes / bytesPerKilobyte
        guard megabytes >= bytesPerKilobyte else { return figure(megabytes) + " MB/s" }
        return figure(megabytes / bytesPerKilobyte) + " GB/s"
    }

    /// One fractional digit below ten, none above, so the figure never runs past three characters.
    private static func figure(_ value: Double) -> String {
        let fractionDigits = value < 10 && value > 0 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never))
    }

    /// Down unless the connection is sending more than it is receiving, which is what an import
    /// looks like. An idle transport keeps the down arrow rather than losing a character.
    private static func arrow(for rate: TransportRate?) -> String {
        guard let rate, rate.sentPerSecond > rate.receivedPerSecond else { return "\u{2193}" }
        return "\u{2191}"
    }

    /// What VoiceOver reads instead of an arrow it would spell out as a glyph name.
    internal static func accessibilityValue(for rate: TransportRate?) -> String {
        let figure = figureAndUnit(for: rate)
        let sending = (rate?.sentPerSecond ?? 0) > (rate?.receivedPerSecond ?? 0)
        return sending
            ? String(format: String(localized: "Sending %@"), figure)
            : String(format: String(localized: "Receiving %@"), figure)
    }
}
