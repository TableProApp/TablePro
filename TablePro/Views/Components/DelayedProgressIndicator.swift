//
//  DelayedProgressIndicator.swift
//  TablePro
//

import SwiftUI

/// A small spinner that only appears once an operation outlasts `LoadingRevealPolicy.grace`, and
/// then stays long enough to be read. AppKit and SwiftUI ship no delayed progress indicator.
///
/// It used to carry the grace and not the dwell, which left it able to flash: work that ended
/// just past the grace showed a spinner for the few milliseconds between the two.
struct DelayedProgressIndicator: View {
    let isActive: Bool

    var body: some View {
        LoadingReveal(isActive: isActive) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
    }
}
