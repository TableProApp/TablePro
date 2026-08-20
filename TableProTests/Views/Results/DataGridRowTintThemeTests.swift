//
//  DataGridRowTintThemeTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// These tests activate a theme on the shared `ThemeEngine`. What keeps that from reaching a suite
/// running in parallel is that both bodies are synchronous and `@MainActor`, so nothing else on the
/// main actor can interleave between activating the test theme and restoring the original one.
/// `.serialized` only orders tests inside this suite and does not provide that. Adding an `await`
/// anywhere between the two would break it.
@Suite("DataGridRowView tint follows the theme", .serialized)
@MainActor
struct DataGridRowTintThemeTests {
    private static let deleted = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])

    private func makeRowView() -> DataGridRowView {
        DataGridRowView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    }

    private func renderedTint(of rowView: DataGridRowView) throws -> NSColor {
        let rep = try #require(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
        rowView.cacheDisplay(in: rowView.bounds, to: rep)
        let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private func theme(_ base: ThemeDefinition, id: String, deletedHex: String) -> ThemeDefinition {
        var copy = base
        copy.id = id
        copy.dataGrid.deleted = deletedHex
        return copy
    }

    @Test("A deleted row takes the new theme's tint even though its state did not change")
    func deletedRowTintFollowsThemeChange() throws {
        let engine = ThemeEngine.shared
        let original = engine.activeTheme
        defer { engine.activateTheme(original) }

        engine.activateTheme(theme(original, id: "test.tint.red", deletedHex: "#FF0000"))
        let rowView = makeRowView()
        rowView.applyVisualState(Self.deleted)
        let firstTint = try renderedTint(of: rowView)

        engine.activateTheme(theme(original, id: "test.tint.blue", deletedHex: "#0000FF"))
        rowView.applyVisualState(Self.deleted)
        let secondTint = try renderedTint(of: rowView)

        #expect(firstTint.redComponent > secondTint.redComponent)
        #expect(secondTint.blueComponent > firstTint.blueComponent)
    }

    @Test("A row with no deleted or inserted state stays untinted across a theme change")
    func plainRowStaysUntinted() throws {
        let engine = ThemeEngine.shared
        let original = engine.activeTheme
        defer { engine.activateTheme(original) }

        engine.activateTheme(theme(original, id: "test.tint.red", deletedHex: "#FF0000"))
        let rowView = makeRowView()
        rowView.applyVisualState(.empty)
        let firstTint = try renderedTint(of: rowView)

        engine.activateTheme(theme(original, id: "test.tint.blue", deletedHex: "#0000FF"))
        rowView.applyVisualState(.empty)
        let secondTint = try renderedTint(of: rowView)

        #expect(firstTint.redComponent == secondTint.redComponent)
        #expect(firstTint.blueComponent == secondTint.blueComponent)
        #expect(firstTint.alphaComponent == 0)
        #expect(secondTint.alphaComponent == 0)
    }
}
