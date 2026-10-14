//
//  DetailPaneBackdropTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@Suite("The detail pane backdrop stops below the toolbar until the toolbar takes the theme", .serialized)
@MainActor
struct DetailPaneBackdropTests {
    private static let insetHeight: CGFloat = 20
    private static let top = CGPoint(x: 0.5, y: 0.1)
    private static let body = CGPoint(x: 0.5, y: 0.6)

    /// The inset stands in for the toolbar's top safe area.
    private func pane(extendsUnderToolbar: Bool) -> some View {
        Color.clear
            .frame(width: 80, height: 80)
            .modifier(DetailPaneBackdropFill(extendsUnderToolbar: extendsUnderToolbar))
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: Self.insetHeight)
            }
    }

    private func nativeBackground() throws -> NSColor {
        try ThemeTestFixture.filled(.background, colorScheme: .dark)
    }

    @Test("The toolbar takes the theme on macOS 26 and later only")
    func gateFollowsTheBackdropRelease() {
        let backdropRelease = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        #expect(DetailPaneBackdrop.extendsUnderToolbar == ProcessInfo.processInfo.isOperatingSystemAtLeast(backdropRelease))
    }

    @Test("The native backdrop always reaches every edge")
    func nativeReachesEveryEdge() {
        #expect(DetailPaneBackdrop.safeAreaEdges(isThemed: false, extendsUnderToolbar: false) == .all)
        #expect(DetailPaneBackdrop.safeAreaEdges(isThemed: false, extendsUnderToolbar: true) == .all)
    }

    @Test("A themed backdrop reaches under the toolbar only where the toolbar takes the theme")
    func themedStopsBelowASystemToolbar() {
        #expect(DetailPaneBackdrop.safeAreaEdges(isThemed: true, extendsUnderToolbar: true) == .all)
        let edges = DetailPaneBackdrop.safeAreaEdges(isThemed: true, extendsUnderToolbar: false)
        #expect(!edges.contains(.top))
        #expect(edges.contains(.bottom) && edges.contains(.leading) && edges.contains(.trailing))
    }

    @Test("Only the window slot themes the backdrop, and Increase Contrast keeps it native")
    func themedOnlyByTheWindowSlot() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            #expect(!DetailPaneBackdrop.isThemed(contrast: .standard))

            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            #expect(DetailPaneBackdrop.isThemed(contrast: .standard))
            #expect(!DetailPaneBackdrop.isThemed(contrast: .increased))

            try ThemeTestFixture.adopt([
                .editorBackground: ThemeTestFixture.editorHex,
                .gridBackground: ThemeTestFixture.gridHex,
            ], appearance: .dark)
            #expect(!DetailPaneBackdrop.isThemed(contrast: .standard))
        }
    }

    @Test("The default pair fills under the toolbar with the system background on both sides of the gate")
    func defaultFillsUnderTheToolbar() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let native = try nativeBackground()
            for extends in [false, true] {
                let top = try ThemeTestFixture.color(of: pane(extendsUnderToolbar: extends), at: Self.top, colorScheme: .dark)
                let body = try ThemeTestFixture.color(of: pane(extendsUnderToolbar: extends), at: Self.body, colorScheme: .dark)
                #expect(ThemeTestFixture.matches(top, native), "extends \(extends): top drew \(top), native \(native)")
                #expect(ThemeTestFixture.matches(body, native), "extends \(extends): body drew \(body), native \(native)")
            }
        }
    }

    @Test("A themed backdrop leaves a system toolbar's safe area unfilled")
    func themedLeavesASystemToolbarAlone() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let themed = try ThemeTestFixture.filled(hex: ThemeTestFixture.windowHex, colorScheme: .dark)
            let top = try ThemeTestFixture.color(of: pane(extendsUnderToolbar: false), at: Self.top, colorScheme: .dark)
            let body = try ThemeTestFixture.color(of: pane(extendsUnderToolbar: false), at: Self.body, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(body, themed), "body drew \(body), theme \(themed)")
            #expect(top.alphaComponent < 0.05, "top drew \(top)")
        }
    }

    @Test("A themed backdrop fills under a toolbar that takes the theme")
    func themedFillsUnderAThemedToolbar() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let themed = try ThemeTestFixture.filled(hex: ThemeTestFixture.windowHex, colorScheme: .dark)
            let top = try ThemeTestFixture.color(of: pane(extendsUnderToolbar: true), at: Self.top, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(top, themed), "top drew \(top), theme \(themed)")
        }
    }
}
