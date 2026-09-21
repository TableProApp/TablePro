//
//  TrailingPaneUnavailableView.swift
//  TablePro
//

import SwiftUI

/// What a trailing surface shows when there is nothing behind it to draw.
///
/// The pane used to be force-collapsed for exactly this state, as part of the chrome the window
/// took down whenever a connection was not up. The window's shape is the user's now and stays put,
/// so a pane they left open needs something honest in it: `Color.clear` was invisible only because
/// nothing ever showed it.
///
/// `ContentUnavailableView` is the right view here and the wrong one for the connecting surface
/// beside it, which is the distinction Apple draws: this is content that cannot be shown, not work
/// in flight.
///
/// It draws the pane's header like every surface does, so the pane's top edge does not jump when a
/// connection drops, and it names why the surface is empty rather than the pane it is in. Every
/// surface used to say "Not Connected" beside `sidebar.right`, including the result column of an Agent
/// mode window whose connection was up and which had no session to show.
internal struct TrailingPaneUnavailableView: View {
    internal enum Reason: Equatable {
        case notConnected
        case noSession

        /// Why the result column cannot draw a session, or nil when it can.
        ///
        /// The connection is asked first, the way the inspector and the assistant ask it. A dropped
        /// connection with a session used to keep its SQL and Results in the column, statements
        /// and rows that could no longer run or be refreshed, beside a detail column that had
        /// already moved to the unavailable screen. Only a live connection with nothing started is
        /// an empty session list.
        internal static func agentResult(pane: ConnectionWindowPane, hasSession: Bool) -> Reason? {
            guard pane.hasContent else { return .notConnected }
            return hasSession ? nil : .noSession
        }
    }

    private let surface: TrailingPaneSurface
    private let reason: Reason
    private let contentMode: ConnectionWorkspaceContentMode
    private let paneState: TrailingPaneState?

    internal init(
        surface: TrailingPaneSurface,
        reason: Reason,
        contentMode: ConnectionWorkspaceContentMode,
        paneState: TrailingPaneState?
    ) {
        self.surface = surface
        self.reason = reason
        self.contentMode = contentMode
        self.paneState = paneState
    }

    internal var body: some View {
        VStack(spacing: 0) {
            TrailingPaneHeaderView(
                surface: surface,
                contentMode: contentMode,
                paneState: paneState,
                hasContent: false
            ) { _ in
                EmptyView()
            }
            UnavailableStateView(
                title,
                systemImage: systemImage,
                description: Text(description)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var title: String {
        switch reason {
        case .notConnected: String(localized: "Not Connected")
        case .noSession: String(localized: "No Session Open")
        }
    }

    /// `bolt.horizontal.circle` is the glyph the connection's own unavailable screen draws for a
    /// dropped connection, and it exists on macOS 13, the app's minimum. `cable.connector.slash`
    /// arrived in macOS 14 and draws nothing on 13.
    private var systemImage: String {
        switch reason {
        case .notConnected: "bolt.horizontal.circle"
        case .noSession: surface.symbolName
        }
    }

    private var description: String {
        switch (surface, reason) {
        case (.inspector, _):
            String(localized: "Row fields appear once the connection is up")
        case (.assistant, _):
            String(localized: "The assistant answers once the connection is up")
        case (.agentResult, .notConnected):
            String(localized: "What the session runs appears once the connection is up")
        case (.agentResult, .noSession):
            String(localized: "What a session proposes and runs appears here")
        }
    }
}
