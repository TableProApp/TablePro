//
//  ExecutingResultPane.swift
//  TablePro
//

import SwiftUI

/// The results pane while a run has nothing loaded to draw yet.
///
/// The gate sits on a view that is always there. Hung on a group that stays empty until revealed,
/// as `LoadingReveal` does, its task never starts and the spinner never appears; the empty group
/// also takes no height, which pulled the status bar up into the middle of the pane.
struct ExecutingResultPane: View {
    @State private var showsProgress = false

    var body: some View {
        Group {
            if showsProgress {
                ProgressView()
                    .accessibilityLabel(String(localized: "Loading…"))
                    .accessibilityIdentifier("results-loading")
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loadingRevealGate(isActive: true, isRevealed: $showsProgress)
    }
}
