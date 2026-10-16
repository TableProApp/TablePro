//
//  CompareWindowThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

/// The Compare & Sync window: a backdrop behind its panes on every macOS version, bars that drop
/// their material over it, and row states that stand in for the grid.
@MainActor
struct CompareWindowThemeTests {
    private static let windowSize = CGSize(width: 720, height: 460)
    private static let paneSize = CGSize(width: 360, height: 240)

    private func makeSession() throws -> (CompareSyncSession, EphemeralDefaults) {
        let suite = try EphemeralDefaults()
        let session = CompareSyncSession(
            profileStorage: CompareSyncProfileStorage(defaults: suite.defaults),
            connectionsProvider: { [] }
        )
        return (session, suite)
    }

    private func color(of view: some View, size: CGSize, at point: CGPoint) throws -> NSColor {
        try ThemeTestFixture.color(
            of: view.frame(width: size.width, height: size.height),
            at: point,
            colorScheme: .dark
        )
    }

    @Test(
        "A row state stands in for the grid in the grid's background",
        arguments: [CompareRowsStandIn.Reason.noRowsMatch, .notCompared("Include this table and compare again.")]
    )
    func rowStateTakesTheGridBackground(reason: CompareRowsStandIn.Reason) throws {
        let view = CompareRowsStandIn(reason: reason)
        let corner = CGPoint(x: 0.03, y: 0.05)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let unthemed = try color(of: view, size: Self.paneSize, at: corner)
            #expect(unthemed.alphaComponent < 0.05, "the default pair drew \(unthemed)")

            try ThemeTestFixture.adopt([.gridBackground: ThemeTestFixture.gridHex], appearance: .dark)
            let grid = try ThemeTestFixture.filled(hex: ThemeTestFixture.gridHex, colorScheme: .dark)
            let themed = try color(of: view, size: Self.paneSize, at: corner)
            #expect(ThemeTestFixture.matches(themed, grid), "drew \(themed), grid \(grid)")

            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let unrelated = try color(of: view, size: Self.paneSize, at: corner)
            #expect(unrelated.alphaComponent < 0.05, "the window slot drew \(unrelated)")
        }
    }

    /// The trailing end of the status bar, where neither the resting line nor a count draws.
    @Test("The status bar drops its material and shows the window theme behind the panes")
    func statusBarShowsTheBackdrop() throws {
        let (session, suite) = try makeSession()
        defer { withExtendedLifetime(suite) {} }
        let view = CompareWindowContentView(session: session, onCompare: {}, onGenerateScript: {}, onApply: {})
        let statusBar = CGPoint(x: 0.97, y: 1 - 14 / Self.windowSize.height)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let window = try ThemeTestFixture.filled(hex: ThemeTestFixture.windowHex, colorScheme: .dark)
            let unthemed = try color(of: view, size: Self.windowSize, at: statusBar)
            #expect(!ThemeTestFixture.matches(unthemed, window))

            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let themed = try color(of: view, size: Self.windowSize, at: statusBar)
            #expect(ThemeTestFixture.matches(themed, window), "status bar drew \(themed), window \(window)")

            try ThemeTestFixture.adopt([.editorBackground: ThemeTestFixture.editorHex], appearance: .dark)
            let unrelated = try color(of: view, size: Self.windowSize, at: statusBar)
            #expect(ThemeTestFixture.matches(unrelated, unthemed), "another slot moved the status bar")
        }
    }

    @Test("The results filter bar keeps its material until the theme colors the window")
    func resultsBarDropsItsMaterial() throws {
        let (session, suite) = try makeSession()
        defer { withExtendedLifetime(suite) {} }
        let view = CompareResultsView(session: session, onCompare: {})
        let bar = CGPoint(x: 0.005, y: 0.01)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let native = try ThemeTestFixture.filled(.bar, colorScheme: .dark)
            let unthemed = try color(of: view, size: Self.paneSize, at: bar)
            #expect(ThemeTestFixture.matches(unthemed, native), "the default pair drew \(unthemed), bar \(native)")

            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let themed = try color(of: view, size: Self.paneSize, at: bar)
            #expect(themed.alphaComponent < 0.05, "the bar drew \(themed) over a themed window")

            try ThemeTestFixture.adopt([.gridBackground: ThemeTestFixture.gridHex], appearance: .dark)
            let unrelated = try color(of: view, size: Self.paneSize, at: bar)
            #expect(ThemeTestFixture.matches(unrelated, native), "another slot drew \(unrelated)")
        }
    }
}
