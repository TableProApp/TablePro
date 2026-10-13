//
//  PaneThemeFixture.swift
//  TableProTests
//

import AppKit
@testable import TablePro

/// A theme that overrides every slot, on the shared engine for the length of `body`. A pane that
/// still reads a slot then takes the override, which is what the native-pane suites look for.
///
/// Synchronous and main-actor on purpose: nothing else on the main actor runs between adopting the
/// theme and restoring the original, so no suite running in parallel sees it.
@MainActor
internal enum PaneThemeFixture {
    static func withEverySlotOverridden<Result>(_ body: () throws -> Result) throws -> Result {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }

        let pair = ThemePair(light: try theme(.light), dark: try theme(.dark))
        engine.adopt(ThemeSelection(pair: pair, effectiveAppearance: restore.effectiveAppearance))
        return try body()
    }

    private static func theme(_ appearance: ThemeAppearance) throws -> ThemeDefinition {
        let override = try ThemeColor(validating: "#FF00FF")
        var overrides: [ThemeSlot: ThemeColor] = [:]
        for slot in ThemeSlot.allCases {
            overrides[slot] = override
        }
        return ThemeDefinition(
            id: "user.test.pane-\(appearance.rawValue)",
            name: "Pane Test",
            author: "",
            appearance: appearance,
            overrides: overrides
        )
    }
}
