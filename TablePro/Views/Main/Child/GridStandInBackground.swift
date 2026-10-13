//
//  GridStandInBackground.swift
//  TablePro
//

import SwiftUI

internal extension QueryResultContent {
    /// A diagram, chart, map, tree or structure view draws its own surface.
    var standsInForGrid: Bool {
        switch self {
        case .idle, .executing, .noRows, .statementSucceeded, .serverOutput, .unavailable:
            return true
        case .structure, .queryPlan, .chart, .map, .json, .grid:
            return false
        }
    }
}

/// Clear unthemed, so the pane keeps its backdrop; under a theme an empty result keeps the grid's color.
private struct GridStandInBackground: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.themeBackground(.gridBackground, native: Color.clear, ignoresSafeAreaEdges: [])
        } else {
            content
        }
    }
}

internal extension View {
    func gridStandInBackground(isActive: Bool = true) -> some View {
        modifier(GridStandInBackground(isActive: isActive))
    }
}
