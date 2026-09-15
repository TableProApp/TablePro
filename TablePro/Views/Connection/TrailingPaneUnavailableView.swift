//
//  TrailingPaneUnavailableView.swift
//  TablePro
//

import SwiftUI

/// What the inspector and the assistant show for a connection that has no session behind them.
///
/// The pane used to be force-collapsed for exactly this state, as part of the chrome the window
/// took down whenever a connection was not up. The window's shape is the user's now and stays put,
/// so a pane they left open needs something honest in it: `Color.clear` was invisible only because
/// nothing ever showed it.
///
/// `ContentUnavailableView` is the right view here and the wrong one for the connecting surface
/// beside it, which is the distinction Apple draws: this is content that cannot be shown, not work
/// in flight.
internal struct TrailingPaneUnavailableView: View {
    internal let surface: TrailingPaneSurface

    internal var body: some View {
        ContentUnavailableView(
            String(localized: "Not Connected"),
            systemImage: "sidebar.right",
            description: Text(description)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var description: String {
        switch surface {
        case .inspector:
            return String(localized: "Row fields appear once the connection is up")
        case .assistant:
            return String(localized: "The assistant answers once the connection is up")
        }
    }
}
