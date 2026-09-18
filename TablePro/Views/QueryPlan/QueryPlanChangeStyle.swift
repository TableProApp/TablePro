//
//  QueryPlanChangeStyle.swift
//  TablePro
//
//  How an added, removed or changed plan node is drawn.
//
//  The glyph is drawn whatever the accessibility settings say, and the tint is what Differentiate
//  Without Color removes. Colour is the redundant channel here, not the load-bearing one, which is
//  what the HIG asks for: "Convey information with more than color alone."
//

import SwiftUI

struct QueryPlanChangeStyle {
    let symbolName: String
    let glyph: String
    let label: String
    let tint: Color

    init(_ kind: QueryPlanNodeChange.Kind) {
        switch kind {
        case .added:
            symbolName = "plus.circle.fill"
            glyph = "+"
            label = String(localized: "Added")
            tint = .green
        case .removed:
            symbolName = "minus.circle.fill"
            glyph = "\u{2212}"
            label = String(localized: "Removed")
            tint = .red
        case .changed:
            symbolName = "pencil.circle.fill"
            glyph = "~"
            label = String(localized: "Changed")
            tint = .orange
        }
    }
}

extension QueryPlanVerdict {
    var symbolName: String {
        switch self {
        case .slower: return "arrow.up.right.circle.fill"
        case .faster: return "arrow.down.right.circle.fill"
        case .shapeChanged: return "arrow.triangle.branch"
        case .valuesChanged: return "equal.circle"
        case .unchanged: return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .slower: return .red
        case .faster: return .green
        case .shapeChanged, .valuesChanged: return .orange
        case .unchanged: return .secondary
        }
    }

    /// The one line the pane leads with. A reader wants to know whether the query got better before
    /// they want to know which node changed.
    var headline: String {
        switch self {
        case .slower(let ratio):
            return String(format: String(localized: "%@ slower than the baseline"), Self.multiple(ratio))
        case .faster(let ratio):
            return String(format: String(localized: "%@ faster than the baseline"), Self.multiple(ratio))
        case .shapeChanged:
            return String(localized: "The plan shape changed")
        case .valuesChanged:
            return String(localized: "Same plan shape, different numbers")
        case .unchanged:
            return String(localized: "No measurable change")
        }
    }

    private static func multiple(_ ratio: Double) -> String {
        String(format: String(localized: "%@x"), ratio.formatted(.number.precision(.fractionLength(0 ... 1))))
    }
}
