//
//  QueryPlanSeverityStyle.swift
//  TablePro
//
//  How a severity is drawn. Cost is diagnostic rather than decorative, so the glyph and the
//  cost text always carry the meaning and colour is only ever a second channel.
//

import SwiftUI

extension QueryPlanSeverity {
    var color: Color {
        switch self {
        case .low: return .green
        case .moderate: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }

    /// Escalating shape, so severity reads without relying on hue.
    var symbolName: String {
        switch self {
        case .low: return "circle.fill"
        case .moderate: return "diamond.fill"
        case .high: return "triangle.fill"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .low: return String(localized: "Low cost")
        case .moderate: return String(localized: "Moderate cost")
        case .high: return String(localized: "High cost")
        case .critical: return String(localized: "Critical cost")
        }
    }

    func tint(differentiateWithoutColor: Bool) -> Color {
        differentiateWithoutColor ? .secondary : color
    }
}
