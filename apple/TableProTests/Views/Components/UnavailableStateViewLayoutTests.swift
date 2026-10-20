//
//  UnavailableStateViewLayoutTests.swift
//  TableProTests
//
//  The connection failure pane offers four buttons. Under the text's 420-point cap they shared
//  356 points and each title truncated, the new Open System Settings to "Open Syst…".
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct UnavailableStateViewLayoutTests {
    @Test("A row of actions wider than the text column keeps its own width")
    func actionsAreNotCappedByTheTextWidth() {
        let view = UnavailableStateView {
            Text("Local Network Access Required")
        } description: {
            Text("A description long enough to wrap at the text column's width, the way a driver error does.")
        } actions: {
            Color.clear.frame(width: 560, height: 20)
        }

        #expect(NSHostingView(rootView: view).fittingSize.width >= 560)
    }

    @Test("The description still wraps at the text column")
    func descriptionStaysInTheTextColumn() {
        let view = UnavailableStateView {
            Text("Title")
        } description: {
            Text(String(repeating: "word ", count: 80))
        }

        #expect(NSHostingView(rootView: view).fittingSize.width <= 420)
    }
}
