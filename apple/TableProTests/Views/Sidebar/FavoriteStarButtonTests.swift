//
//  FavoriteStarButtonTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct FavoriteStarButtonTests {
    private static func host(_ view: some View) -> (NSHostingView<AnyView>, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        window.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    private static func star(isFavorite: Bool, isRowHovered: Bool) -> FavoriteStarButton {
        FavoriteStarButton(isFavorite: isFavorite, isRowHovered: isRowHovered, toggle: {})
    }

    // SwiftUI's own view hierarchy is private: only check for the control's views where a button has them.
    static func buttonsAddAppKitViews() -> Bool {
        let (hosting, window) = host(Button("Star") {}.buttonStyle(.plain))
        defer { window.orderOut(nil) }
        return !hosting.subviews.isEmpty
    }

    @Test(
        "A hidden star puts no control in its row, and a shown one does",
        .enabled("a SwiftUI button adds AppKit views on this macOS") { await FavoriteStarButtonTests.buttonsAddAppKitViews() }
    )
    func hiddenStarIsNoControl() {
        for (isFavorite, isRowHovered, expectsControl) in [(false, false, false), (false, true, true), (true, false, true)] {
            let (hosting, window) = Self.host(Self.star(isFavorite: isFavorite, isRowHovered: isRowHovered))
            #expect(hosting.subviews.isEmpty == !expectsControl, "favorite \(isFavorite), hovered \(isRowHovered)")
            window.orderOut(nil)
        }
    }

    @Test("A star takes the same room hidden as shown, so a hover moves nothing in the row")
    func hiddenStarKeepsItsRoom() {
        let hidden = NSHostingView(rootView: Self.star(isFavorite: false, isRowHovered: false)).fittingSize
        let shown = NSHostingView(rootView: Self.star(isFavorite: false, isRowHovered: true)).fittingSize
        #expect(hidden == shown)
        #expect(hidden == CGSize(width: 20, height: 20))
    }
}
