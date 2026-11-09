//
//  FilterRowLayout.swift
//  TablePro
//

import SwiftUI

// An HStack hands out width greedily, so its rows overflow a narrow pane and drift apart at middle
// widths; every row here gives way the same amount, keeping its cells on one grid at any width.
struct FilterRowLayout: Layout {
    // A slot's minimum is declared rather than read from its control, so every row gives way alike.
    enum Role: Equatable {
        case fixed
        case reserved(CGFloat, minimum: CGFloat)
        // Keeps the slot's width in the grid, and the fill cell after it starts at the slot instead.
        case spannedByFill(CGFloat, minimum: CGFloat)
        case fill
    }

    var spacing: CGFloat
    // The same for every row, so a row with a smaller value cell still gives way like the others.
    var fillMinimum: CGFloat = 0

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
            case .reserved(let target, let minimum), .spannedByFill(let target, let minimum):
                reserved.append((index, target, minimum))
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
        let forReserved = max(available - fills.reduce(0) { $0 + $1.minimum }, 0)
        for (index, width) in Self.share(forReserved, among: reserved) {
            widths[index] = width
            available -= width
        }
        let fillShare = fills.isEmpty ? 0 : available / CGFloat(fills.count)
        for cell in fills { widths[cell.index] = max(fillShare, cell.minimum) }
        return widths
    }

    // Scales the slots down together; one that reaches its minimum stays there and the rest share what is left.
    private static func share(
        _ budget: CGFloat,
        among slots: [(index: Int, target: CGFloat, minimum: CGFloat)]
    ) -> [(index: Int, width: CGFloat)] {
        var open = slots
        var budget = budget
        var shares: [(index: Int, width: CGFloat)] = []
        while !open.isEmpty {
            let targets = open.reduce(0) { $0 + $1.target }
            guard targets > budget, targets > 0 else {
                return shares + open.map { ($0.index, $0.target) }
            }
            let scale = budget / targets
            let clamped = open.filter { $0.target * scale < $0.minimum }
            guard !clamped.isEmpty else {
                return shares + open.map { ($0.index, $0.target * scale) }
            }
            for slot in clamped {
                shares.append((slot.index, slot.minimum))
                budget = max(budget - slot.minimum, 0)
            }
            open.removeAll { slot in clamped.contains { $0.index == slot.index } }
        }
        return shares
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
