//
//  DetailColumnBackdrop.swift
//  TablePro
//

import AppKit
import SwiftUI

/// `window.background` under whatever the detail column shows, on every macOS version: Connecting,
/// Unavailable and the agent conversation draw no backdrop of their own, and before macOS 26 the
/// window color does not take the theme.
@MainActor
internal enum DetailColumnBackdrop {
    internal static func makeView() -> NSView {
        let view = DetailColumnBackdropView(rootView: DetailColumnBackdropSurface())
        view.sizingOptions = []
        return view
    }
}

private struct DetailColumnBackdropSurface: View {
    var body: some View {
        Color.clear
            .modifier(DetailPaneBackdropFill())
            .accessibilityHidden(true)
    }
}

// A point the pane above leaves unclaimed still reaches the window, as it did with no backdrop.
private final class DetailColumnBackdropView: NSHostingView<DetailColumnBackdropSurface> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
