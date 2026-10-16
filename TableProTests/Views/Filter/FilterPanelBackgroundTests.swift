//
//  FilterPanelBackgroundTests.swift
//  TableProTests
//
//  The filter bar is chrome: it keeps its system fills until the window backdrop is themed, then
//  draws nothing and shows the themed pane behind it. It used to paint `window.background` itself,
//  which read the theme from a chrome file.
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct FilterPanelBackgroundTests {
    private var panel: some View {
        FilterPanelView(
            state: .constant(TabFilterState()),
            configuration: FilterPanelConfiguration(
                columns: [],
                primaryKeyColumn: nil,
                offersRawFilter: false,
                caseMatching: .inMemory,
                sqlPreview: nil,
                presetStore: nil
            ),
            actions: DataFileController()
        )
        .frame(width: 480)
    }

    private static let headerPoint = CGPoint(x: 0.004, y: 0.1)

    @Test("Under the default pair the header keeps its control background")
    func defaultIsNative() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let drawn = try ThemeTestFixture.color(of: panel, at: Self.headerPoint, colorScheme: .dark)
            let native = try ThemeTestFixture.filled(.controlBackgroundColor, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(drawn, native), "drew \(drawn), native \(native)")
        }
    }

    @Test("Under a themed window backdrop the bar draws nothing, so the pane's theme shows through")
    func themedBackdropDrawsNothing() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let drawn = try ThemeTestFixture.color(of: panel, at: Self.headerPoint, colorScheme: .dark)
            #expect(drawn.alphaComponent < 0.02, "drew \(drawn)")
        }
    }

    @Test("A theme that leaves the window alone leaves the bar's system fill")
    func otherSlotsKeepTheNativeFill() throws {
        try ThemeTestFixture.adopting(
            [.editorBackground: ThemeTestFixture.editorHex, .gridBackground: ThemeTestFixture.gridHex],
            appearance: .dark
        ) {
            let drawn = try ThemeTestFixture.color(of: panel, at: Self.headerPoint, colorScheme: .dark)
            let native = try ThemeTestFixture.filled(.controlBackgroundColor, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(drawn, native), "drew \(drawn), native \(native)")
        }
    }
}
