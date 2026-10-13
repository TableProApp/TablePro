//
//  GridStandInBackgroundTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Result states that stand in for the grid", .serialized)
@MainActor
struct GridStandInBackgroundTests {
    private static let center = CGPoint(x: 0.5, y: 0.5)

    @Test("Only the states drawn where the grid sits take the grid's background")
    func onlyGridStandInsQualify() {
        let output = PluginServerOutput(lines: ["done"], isTruncated: false)
        let cases: [(QueryResultContent, Bool)] = [
            (.idle, true),
            (.executing, true),
            (.noRows(executionTime: 0.1), true),
            (.statementSucceeded(rowsAffected: 1, executionTime: nil, statusMessage: nil, serverOutput: .none), true),
            (.serverOutput(output), true),
            (.unavailable(mode: .chart), true),
            (.grid, false),
            (.json, false),
            (.chart, false),
            (.map, false),
            (.queryPlan, false),
            (.structure(tableName: "orders"), false),
        ]
        for (content, expected) in cases {
            #expect(content.standsInForGrid == expected, "\(content)")
        }
    }

    private var swatch: some View {
        Color.clear.frame(width: 24, height: 24).gridStandInBackground()
    }

    @Test("The default pair draws nothing, so the pane's own backdrop shows as it did")
    func defaultPairDrawsNothing() throws {
        try ThemeSurfaceProbe.adopting(dark: BuiltInThemes.dark) {
            let drawn = try ThemeSurfaceProbe.color(of: swatch, at: Self.center)
            #expect(drawn.alphaComponent < 0.01, "drew \(drawn)")
        }
    }

    @Test("A theme that sets the grid background fills the stand-in with it")
    func gridThemeFillsTheStandIn() throws {
        let theme = try ThemeSurfaceProbe.darkTheme([.gridBackground: ThemeSurfaceProbe.gridHex])
        try ThemeSurfaceProbe.adopting(dark: theme) {
            let drawn = try ThemeSurfaceProbe.color(of: swatch, at: Self.center)
            let expected = try ThemeSurfaceProbe.filled(hex: ThemeSurfaceProbe.gridHex)
            #expect(ThemeSurfaceProbe.matches(drawn, expected), "drew \(drawn), theme \(expected)")
        }
    }

    @Test("A window or editor color alone leaves the stand-in clear")
    func otherSlotsLeaveItClear() throws {
        let theme = try ThemeSurfaceProbe.darkTheme([
            .windowBackdrop: ThemeSurfaceProbe.windowHex,
            .editorBackground: ThemeSurfaceProbe.editorHex,
        ])
        try ThemeSurfaceProbe.adopting(dark: theme) {
            let drawn = try ThemeSurfaceProbe.color(of: swatch, at: Self.center)
            #expect(drawn.alphaComponent < 0.01, "drew \(drawn)")
        }
    }

    @Test("A region that is not a stand-in stays clear under a grid theme")
    func inactiveRegionStaysClear() throws {
        let theme = try ThemeSurfaceProbe.darkTheme([.gridBackground: ThemeSurfaceProbe.gridHex])
        try ThemeSurfaceProbe.adopting(dark: theme) {
            let region = Color.clear.frame(width: 24, height: 24).gridStandInBackground(isActive: false)
            let drawn = try ThemeSurfaceProbe.color(of: region, at: Self.center)
            #expect(drawn.alphaComponent < 0.01, "drew \(drawn)")
        }
    }
}
