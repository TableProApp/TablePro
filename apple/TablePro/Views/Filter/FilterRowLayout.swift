//
//  FilterRowLayout.swift
//  TablePro
//

import SwiftUI

// An HStack hands out width greedily, so its rows overflow a narrow pane and drift apart at middle
// widths; every row here gives way the same amount, keeping its cells on one grid at any width.
struct FilterRowLayout: Layout {
    enum Role: Equatable {
        case fixed
        case reserved(CGFloat)
        // Keeps the slot's width in the grid, and the fill cell after it starts at the slot instead.
        case spannedByFill(CGFloat)
        case fill
    }

    var spacing: CGFloat
    // The same for every row, so a row with a smaller value cell still gives way like the others.
    var fillMinimum: CGFloat = 0
    // Likewise for reserved slots, so an empty placeholder shrinks no further than the pop-up it stands for.
    var reservedMinimum: CGFloat = FilterControlMetrics.popUpMinimumWidth

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews: subviews)
        let line = lineExtent(frames: frames(widths: widths, subviews: subviews), subviews: subviews)
        return CGSize(width: widths.reduce(0, +) + gaps(subviews), height: line.above + line.below)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(widths: widths(for: bounds.width, subviews: subviews), subviews: subviews)
        let line = lineExtent(frames: frames, subviews: subviews)
        let lineY = bounds.minY + (bounds.height - line.above - line.below) / 2 + line.above
        for (subview, frame) in zip(subviews, frames) {
            let proposal = ProposedViewSize(width: frame.width, height: nil)
            let guide = subview.dimensions(in: proposal)[.filterRowLine]
            subview.place(at: CGPoint(x: bounds.minX + frame.x, y: lineY - guide), anchor: .topLeading, proposal: proposal)
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(subviews.count - 1, 0))
    }

    private func frames(widths: [CGFloat], subviews: Subviews) -> [(x: CGFloat, width: CGFloat)] {
        var frames: [(x: CGFloat, width: CGFloat)] = []
        var x: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if subviews[index][FilterRowRoleKey.self] == .fill,
               let previous = frames.last,
               case .spannedByFill = subviews[index - 1][FilterRowRoleKey.self] {
                frames.append((previous.x, x + width - previous.x))
            } else {
                frames.append((x, width))
            }
            x += width + spacing
        }
        return frames
    }

    private func lineExtent(frames: [(x: CGFloat, width: CGFloat)], subviews: Subviews) -> (above: CGFloat, below: CGFloat) {
        var above: CGFloat = 0
        var below: CGFloat = 0
        for (subview, frame) in zip(subviews, frames) {
            let dimensions = subview.dimensions(in: ProposedViewSize(width: frame.width, height: nil))
            above = max(above, dimensions[.filterRowLine])
            below = max(below, dimensions.height - dimensions[.filterRowLine])
        }
        return (above, below)
    }

    private func widths(for proposedWidth: CGFloat?, subviews: Subviews) -> [CGFloat] {
        var widths = [CGFloat](repeating: 0, count: subviews.count)
        var reserved: [(index: Int, target: CGFloat, minimum: CGFloat)] = []
        var fills: [(index: Int, minimum: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            switch subview[FilterRowRoleKey.self] {
            case .fixed:
                widths[index] = subview.sizeThatFits(.unspecified).width
            case .reserved(let target):
                reserved.append((index, target, max(minimumWidth(of: subview), reservedMinimum)))
            case .spannedByFill(let target):
                reserved.append((index, target, reservedMinimum))
            case .fill:
                fills.append((index, max(minimumWidth(of: subview), fillMinimum)))
            }
        }

        guard let proposedWidth else {
            for cell in reserved { widths[cell.index] = cell.target }
            for cell in fills {
                widths[cell.index] = max(subviews[cell.index].sizeThatFits(.unspecified).width, cell.minimum)
            }
            return widths
        }

        var available = proposedWidth - gaps(subviews) - widths.reduce(0, +)
        let targets = reserved.reduce(0) { $0 + $1.target }
        let forReserved = max(available - fills.reduce(0) { $0 + $1.minimum }, 0)
        let scale = targets > forReserved && targets > 0 ? forReserved / targets : 1
        for cell in reserved {
            widths[cell.index] = max(cell.target * scale, cell.minimum)
            available -= widths[cell.index]
        }
        let fillShare = fills.isEmpty ? 0 : available / CGFloat(fills.count)
        for cell in fills { widths[cell.index] = max(fillShare, cell.minimum) }
        return widths
    }

    private func minimumWidth(of subview: LayoutSubview) -> CGFloat {
        subview.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
    }
}

private struct FilterRowRoleKey: LayoutValueKey {
    static let defaultValue: FilterRowLayout.Role = .fixed
}

extension View {
    func filterRowRole(_ role: FilterRowLayout.Role) -> some View {
        layoutValue(key: FilterRowRoleKey.self, value: role)
    }
}
