//
//  QueryPlanMagnitudeCellView.swift
//  TablePro
//
//  One plan node's chosen metric, drawn as a bar against the largest node in the plan.
//
//  Drawn rather than built from a control. A progress indicator is the wrong instrument: the HIG
//  calls them transient, "appearing only while an operation is ongoing", and says a stationary one
//  reads as a stalled app. `NSLevelIndicator`'s relevancy style is what the HIG names for
//  comparing items, but measured against the real framework it draws no fill at any value and
//  ignores `fillColor`, so it has no channel for severity. `Canvas` is what the plan diagram
//  beside this already draws with.
//

import SwiftUI

struct QueryPlanMagnitudeCellView: View {
    let fraction: Double?
    let valueText: String?
    let severity: QueryPlanSeverity?
    let metric: QueryPlanBarMetric
    let emphasisText: String?
    let differentiateWithoutColor: Bool

    private enum Metrics {
        static let barHeight: CGFloat = 6
        static let labelWidth: CGFloat = 58
        static let spacing: CGFloat = 8
        /// A node that did a thousandth of the largest node's work still did some. Rounding its bar
        /// away would read as "nothing reported", which is a different statement.
        static let minimumVisibleWidth: CGFloat = 2
    }

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            bar
            Text(valueText ?? "")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Metrics.labelWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(accessibilityValue)
    }

    private var bar: some View {
        Canvas { context, size in
            let top = (size.height - Metrics.barHeight) / 2
            let track = CGRect(x: 0, y: top, width: size.width, height: Metrics.barHeight)
            context.fill(capsule(track), with: .color(Color(nsColor: .quaternaryLabelColor)))

            guard let fraction, fraction > 0 else { return }
            let width = max(Metrics.minimumVisibleWidth, track.width * fraction)
            var fill = track
            fill.size.width = min(width, track.width)
            context.fill(capsule(fill), with: .color(tint))
        }
        .accessibilityHidden(true)
    }

    private func capsule(_ rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: Metrics.barHeight / 2)
    }

    /// A metric with no severity is not a metric in trouble, it is one whose bands do not apply, so
    /// it takes the accent colour rather than the muted grey that reads as missing data.
    private var tint: Color {
        guard !differentiateWithoutColor else { return .secondary }
        return severity?.color ?? .accentColor
    }

    private var accessibilityValue: String {
        guard let valueText else { return QueryPlanValueFormatter.absent }
        guard let emphasisText else { return valueText }
        return "\(valueText), \(metric.emphasisDescription(emphasisText))"
    }
}
