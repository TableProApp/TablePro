//
//  StatusBarChromeTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct StatusBarChromeTests {
    private static func host(_ view: some View) -> NSHostingView<AnyView> {
        ThemeTestFixture.hostingView(view, size: NSSize(width: 240, height: StatusBarChrome.height + 1))
    }

    private static func drawsMaterial(_ host: NSView) -> Bool {
        host.layoutSubtreeIfNeeded()
        return containsMaterial(host)
    }

    private static func containsMaterial(_ view: NSView) -> Bool {
        view.subviews.contains { $0 is NSVisualEffectView || containsMaterial($0) }
    }

    private static var bar: some View {
        Text(verbatim: "1 row").statusBarChrome()
    }

    @Test("A bar draws its material under the default pair")
    func materialByDefault() {
        ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            #expect(Self.drawsMaterial(Self.host(Self.bar)))
        }
    }

    @Test("A bar over a themed backdrop draws no material")
    func noMaterialOverAThemedBackdrop() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            #expect(!Self.drawsMaterial(Self.host(Self.bar)))
        }
    }

    @Test("A bar drops its material while the window slot themes the backdrop, and gets it back after")
    func barFollowsTheBackdrop() throws {
        let window = try ThemeTestFixture.pair([.windowBackdrop: ThemeTestFixture.windowHex], on: .dark)
        let content = try ThemeTestFixture.pair([
            .editorBackground: ThemeTestFixture.editorHex,
            .gridBackground: ThemeTestFixture.gridHex,
        ], on: .dark)
        ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let host = Self.host(Self.bar)
            #expect(Self.drawsMaterial(host), "default pair")

            ThemeTestFixture.adopt(window, appearance: .dark)
            #expect(!Self.drawsMaterial(host), "window theme")

            ThemeTestFixture.adopt(content, appearance: .dark)
            #expect(Self.drawsMaterial(host), "content theme")

            ThemeTestFixture.adopt(.builtIn, appearance: .dark)
            #expect(Self.drawsMaterial(host), "default pair again")
        }
    }

    @Test("A bar keeps its material under Increase Contrast, where the backdrop stays native")
    func increaseContrastKeepsTheMaterial() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            #expect(!ThemeBackdropState.isThemed(highContrast: true))
        }
    }
}
