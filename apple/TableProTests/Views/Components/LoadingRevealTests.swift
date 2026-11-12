//
//  LoadingRevealTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

private struct Square: View {
    var body: some View {
        Color.clear.frame(width: 10, height: 10)
    }
}

// The reveal used to hang its timer on an empty group, whose task never starts, so nothing ever appeared.
@MainActor
struct LoadingRevealTests {
    private func host<Content: View>(_ content: Content) -> (NSWindow, NSHostingView<Content>) {
        let view = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (window, view)
    }

    @Test("A delayed indicator appears once the work outlasts the grace")
    func revealsAfterTheGrace() async throws {
        let (window, view) = host(HStack(spacing: 8) { Square(); DelayedProgressIndicator(isActive: true); Square() })
        defer { window.orderOut(nil) }

        #expect(view.fittingSize.width == 28, "nothing shows inside the grace")
        try await waitUntil(timeout: .seconds(5)) { view.fittingSize.width > 28 }
    }

    @Test("A held-back indicator takes no room and no stack spacing")
    func heldBackTakesNoSpacing() {
        let (bareWindow, bare) = host(HStack(spacing: 8) { Square(); Square() })
        let (window, held) = host(HStack(spacing: 8) { Square(); DelayedProgressIndicator(isActive: false); Square() })
        defer {
            bareWindow.orderOut(nil)
            window.orderOut(nil)
        }

        #expect(held.fittingSize.width == bare.fittingSize.width)
    }

    @Test("The readout's loading spinner reveals too")
    func readoutLoadingReveals() async throws {
        let (window, view) = host(ResultStatusReadoutView(readout: .loading))
        defer { window.orderOut(nil) }

        try await waitUntil(timeout: .seconds(5)) { view.fittingSize.width > 0 }
    }

    @Test("The readout draws no spinner while the execution indicator owns it")
    func readoutYieldsTheSpinner() async throws {
        let (window, view) = host(ResultStatusReadoutView(readout: .loading, showsLoadingIndicator: false))
        let (spinnerWindow, spinner) = host(ResultStatusReadoutView(readout: .loading))
        defer {
            window.orderOut(nil)
            spinnerWindow.orderOut(nil)
        }

        try await waitUntil(timeout: .seconds(5)) { spinner.fittingSize.width > 0 }
        #expect(view.fittingSize.width == 0)
    }
}
