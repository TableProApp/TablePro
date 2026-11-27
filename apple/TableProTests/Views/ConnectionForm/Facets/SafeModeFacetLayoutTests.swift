//
//  SafeModeFacetLayoutTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct SafeModeFacetLayoutTests {
    // The default window is 780 pt wide with a 220 pt sidebar.
    private static let detailWidth: CGFloat = 560

    private func storeWithEveryMaskingStyle() throws -> (ConnectionEditorStoreFixture, ConnectionEditorStore) {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        for style in MaskingStyle.allCases {
            let id = store.addMaskingRule()
            store.updateMaskingRule(MaskingRule(id: id, pattern: "customers.billing_email_address", target: .type, style: style))
        }
        return (fixture, store)
    }

    private func flush(_ window: NSWindow) {
        for _ in 0..<3 {
            RunLoop.main.run(until: Date())
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    @Test("Masking rules never make the Safe Mode page wider than the detail column")
    func maskingRulesFitTheDetailColumn() throws {
        let (fixture, store) = try storeWithEveryMaskingStyle()
        defer { withExtendedLifetime(fixture) {} }
        let proposal = CGSize(width: Self.detailWidth, height: 700)

        let controller = NSHostingController(rootView: SafeModeFacetView(store: store))
        #expect(controller.sizeThatFits(in: proposal).width <= Self.detailWidth + 0.5)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: proposal),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        controller.view.frame = NSRect(origin: .zero, size: proposal)
        window.contentView?.addSubview(controller.view)
        flush(window)

        var stack: [NSView] = [controller.view]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard let scrollView = view as? NSScrollView else { continue }
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            #expect(frame.minX >= -0.5, "\(frame)")
            #expect(frame.maxX <= Self.detailWidth + 0.5, "\(frame)")
        }
    }
}
