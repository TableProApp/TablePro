//
//  DataGridRowTintThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
private final class FixedVisualStateDelegate: DataGridViewDelegate {
    var state: RowVisualState

    init(state: RowVisualState) {
        self.state = state
    }

    func dataGridVisualState(forRow row: Int) -> RowVisualState? { state }
}

@MainActor
private final class NoopColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// These tests activate a theme on the shared `ThemeEngine`. What keeps that from reaching a suite
/// running in parallel is that both bodies are synchronous and `@MainActor`, so nothing else on the
/// main actor can interleave between activating the test theme and restoring the original one.
/// `.serialized` only orders tests inside this suite and does not provide that. Adding an `await`
/// anywhere between the two would break it.
@Suite("DataGridRowView tint follows the theme", .serialized)
@MainActor
struct DataGridRowTintThemeTests {
    private static let deleted = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])

    private final class Harness {
        let delegate: FixedVisualStateDelegate
        let coordinator: TableViewCoordinator
        let rowView: DataGridRowView

        @MainActor
        init(state: RowVisualState) {
            delegate = FixedVisualStateDelegate(state: state)
            coordinator = TableViewCoordinator(
                changeManager: AnyChangeManager(DataChangeManager()),
                isEditable: false,
                selectedRowIndices: .constant([]),
                delegate: delegate,
                layoutPersister: NoopColumnLayoutPersister()
            )
            rowView = DataGridRowView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            rowView.coordinator = coordinator
            rowView.rowIndex = 0
        }
    }

    private func makeRowView(state: RowVisualState) -> Harness {
        Harness(state: state)
    }

    private func renderedTint(of rowView: DataGridRowView) throws -> NSColor {
        let rep = try #require(rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds))
        rowView.cacheDisplay(in: rowView.bounds, to: rep)
        let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private func selection(_ base: ThemeDefinition, id: String, deletedHex: String) -> ThemeSelection {
        var copy = base
        copy.id = id
        copy.dataGrid.deleted = .hex(deletedHex)

        let pair = copy.appearance == .dark
            ? ThemePair(light: BuiltInThemes.light, dark: copy)
            : ThemePair(light: copy, dark: BuiltInThemes.dark)

        return ThemeSelection(pair: pair, effectiveAppearance: copy.appearance)
    }

    @Test("A deleted row takes the new theme's tint even though its state did not change")
    func deletedRowTintFollowsThemeChange() throws {
        let engine = ThemeEngine.shared
        let original = engine.activeTheme
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }

        engine.adopt(selection(original, id: "test.tint.red", deletedHex: "#FF0000"))
        let harness = makeRowView(state: Self.deleted)
        let firstTint = try renderedTint(of: harness.rowView)

        engine.adopt(selection(original, id: "test.tint.blue", deletedHex: "#0000FF"))
        harness.rowView.invalidateVisualState()
        let secondTint = try renderedTint(of: harness.rowView)

        #expect(firstTint.redComponent > secondTint.redComponent)
        #expect(secondTint.blueComponent > firstTint.blueComponent)
    }

    @Test("A row paints the state its coordinator reports now, not one pushed into it earlier")
    func rowPaintsTheLiveState() throws {
        let engine = ThemeEngine.shared
        let original = engine.activeTheme
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        engine.adopt(selection(original, id: "test.tint.red", deletedHex: "#FF0000"))

        let harness = makeRowView(state: .empty)
        let before = try renderedTint(of: harness.rowView)
        harness.delegate.state = Self.deleted
        let after = try renderedTint(of: harness.rowView)

        #expect(before.alphaComponent == 0)
        #expect(after.redComponent > 0.5)
        #expect(harness.rowView.visualState == Self.deleted)
    }

    @Test("A pending delete keeps its wash over a matching highlight rule")
    func pendingDeleteOutranksHighlightWash() throws {
        let engine = ThemeEngine.shared
        let original = engine.activeTheme
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        engine.adopt(selection(original, id: "test.tint.red", deletedHex: "#FF0000"))

        let highlight = RowHighlight(
            rowRule: HighlightRule(columnName: "status", value: "paid", color: .blue),
            cellRules: [:]
        )
        let harness = makeRowView(state: Self.deleted.highlighted(highlight))
        let tint = try renderedTint(of: harness.rowView)

        #expect(tint.redComponent > tint.blueComponent)
        #expect(Self.deleted.highlighted(highlight).tint == engine.palette[.gridDeleted])
        #expect(RowVisualState.empty.highlighted(highlight).tint == HighlightColor.blue.washColor)
    }

    @Test("A row with no deleted or inserted state stays untinted across a theme change")
    func plainRowStaysUntinted() throws {
        let engine = ThemeEngine.shared
        let original = engine.activeTheme
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }

        engine.adopt(selection(original, id: "test.tint.red", deletedHex: "#FF0000"))
        let harness = makeRowView(state: .empty)
        let firstTint = try renderedTint(of: harness.rowView)

        engine.adopt(selection(original, id: "test.tint.blue", deletedHex: "#0000FF"))
        harness.rowView.invalidateVisualState()
        let secondTint = try renderedTint(of: harness.rowView)

        #expect(firstTint.redComponent == secondTint.redComponent)
        #expect(firstTint.blueComponent == secondTint.blueComponent)
        #expect(firstTint.alphaComponent == 0)
        #expect(secondTint.alphaComponent == 0)
    }
}
