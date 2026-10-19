//
//  ResultChartLegend.swift
//  TablePro
//

import Charts
import SwiftUI

/// The legend of a faceted chart. Swift Charts draws a legend only inside one chart, so this one
/// draws the same symbol, colour and dash each panel takes from `ResultChartSeriesStyle`, because
/// colour alone does not tell two series apart.
struct ResultChartLegend: View {
    let title: String?
    let style: ResultChartSeriesStyle
    let showsStroke: Bool

    var body: some View {
        LegendFlowLayout(spacing: 10, lineSpacing: 6) {
            ForEach(style.entries) { entry in
                HStack(spacing: 6) {
                    swatch(for: entry)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(entry.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.name)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? String(localized: "Series"))
    }

    private func swatch(for entry: ResultChartSeriesStyle.Entry) -> some View {
        ZStack {
            if showsStroke {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 5))
                    path.addLine(to: CGPoint(x: 20, y: 5))
                }
                .stroke(entry.color, style: entry.stroke)
            }
            entry.symbol
                .fill(entry.color)
                .frame(width: 8, height: 8)
        }
        .frame(width: showsStroke ? 20 : 8, height: 10)
    }
}

/// Entries side by side at their own width, wrapping to a new line, the way the chart's own legend
/// lays them out.
private struct LegendFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + lineSpacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
