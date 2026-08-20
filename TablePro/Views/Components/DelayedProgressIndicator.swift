//
//  DelayedProgressIndicator.swift
//  TablePro
//

import SwiftUI

/// A spinner that only appears once an operation outlasts `delay`. AppKit and SwiftUI
/// ship no delayed progress indicator, so short refreshes would otherwise flash a
/// spinner that resolves before the user can read it.
struct DelayedProgressIndicator: View {
    let isActive: Bool
    var delay: Duration = .milliseconds(500)

    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
        }
        .task(id: isActive) {
            guard isActive else {
                isVisible = false
                return
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isVisible = true
        }
    }
}
