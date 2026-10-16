//
//  CellOverlayAppearanceTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTheme
import Testing

@MainActor
private final class OverlayLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// `appAppearanceChangeRepaintsAnOpenOverlay` assigns `NSApp.appearance`, which is global. What keeps
/// that from reaching a suite running in parallel is that the body is synchronous and `@MainActor`,
/// so nothing else on the main actor can interleave before the `defer` restores it. `.serialized`
/// only orders tests inside this suite. Adding an `await` would break it.
@MainActor
struct CellOverlayAppearanceTests {
    private func makeContainer() -> CellOverlayContainerView {
        CellOverlayBase.makeContainer(frame: NSRect(x: 0, y: 0, width: 120, height: 24), scope: .live)
    }

    private func components(of color: CGColor?) throws -> (brightness: CGFloat, alpha: CGFloat) {
        let cgColor = try #require(color)
        let nsColor = try #require(NSColor(cgColor: cgColor))
        let srgb = try #require(nsColor.usingColorSpace(.sRGB))
        let brightness = (srgb.redComponent + srgb.greenComponent + srgb.blueComponent) / 3
        return (brightness, srgb.alphaComponent)
    }

    @Test("A container built under each appearance gets that appearance's colours")
    func containerColoursDifferByAppearance() throws {
        let light = makeContainer()
        light.appearance = try #require(NSAppearance(named: .aqua))
        let dark = makeContainer()
        dark.appearance = try #require(NSAppearance(named: .darkAqua))

        let lightBackground = try components(of: light.layer?.backgroundColor)
        let darkBackground = try components(of: dark.layer?.backgroundColor)
        let lightBorder = try components(of: light.layer?.borderColor)
        let darkBorder = try components(of: dark.layer?.borderColor)

        #expect(lightBackground.brightness > darkBackground.brightness)
        #expect(lightBorder.brightness != darkBorder.brightness)
    }

    /// The real trigger. `ThemeEngine.applyNSAppAppearance` assigns `NSApp.appearance`, and on that
    /// path a view's `effectiveAppearance` is already the new one while
    /// `NSAppearance.currentDrawing()` is still the old one, so a bare `.cgColor` resolves to the old
    /// colour. Setting `container.appearance` directly does not reproduce that and would pass even
    /// without `performAsCurrentDrawingAppearance`. The container has to be in a real window.
    ///
    /// The window has to be held across the flip. AppKit does not retain a window that was never
    /// ordered front, and this one's last use is the `contentView` read below, so an autorelease pool
    /// draining between that and the flip deallocates it. Measured: after a pool drain the window is
    /// gone, `NSApp.windows` is empty, the container's `window` is nil, and the appearance change
    /// produces zero `viewDidChangeEffectiveAppearance` calls, leaving `effectiveAppearance` at Aqua
    /// and both reads at the light colour. That is the failure this suite showed once and could not
    /// explain, and it is intermittent because where the pool drains is not the test's to decide.
    @Test("An app appearance change repaints an open overlay")
    func appAppearanceChangeRepaintsAnOpenOverlay() throws {
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }

        NSApp.appearance = try #require(NSAppearance(named: .aqua))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let contentView = try #require(window.contentView)
        contentView.addSubview(tableView)

        let container = makeContainer()
        tableView.addSubview(container)

        try withExtendedLifetime(window) {
            let lightBackground = try components(of: container.layer?.backgroundColor)
            let lightBorder = try components(of: container.layer?.borderColor)

            NSApp.appearance = try #require(NSAppearance(named: .darkAqua))

            #expect(container.window === window)
            #expect(container.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)

            let darkBackground = try components(of: container.layer?.backgroundColor)
            let darkBorder = try components(of: container.layer?.borderColor)

            #expect(lightBackground.brightness > darkBackground.brightness)
            #expect(lightBorder.brightness != darkBorder.brightness)
        }
    }

    /// The border is a baked `CGColor`, so a theme change reaches an open editor only by being
    /// applied again, which the `themeChanged` subscription does.
    @Test("A theme's focus border reaches an open overlay when its colours are reapplied")
    func themeFocusBorderIsRebaked() throws {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        engine.adopt(ThemeSelection(pair: .builtIn, effectiveAppearance: .light))

        let container = makeContainer()
        container.appearance = try #require(NSAppearance(named: .aqua))
        let nativeBorder = try #require(container.layer?.borderColor)

        var theme = BuiltInThemes.light
        theme.id = "test.overlay-border"
        theme.overrides[.gridFocusBorder] = try ThemeColor(validating: "#FF0000")
        engine.adopt(ThemeSelection(pair: ThemePair(light: theme, dark: BuiltInThemes.dark), effectiveAppearance: .light))
        container.applyLayerColors()

        let themed = try #require(container.layer?.borderColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(themed.redComponent > 0.9)
        #expect(themed.greenComponent < 0.1)
        #expect(themed.blueComponent < 0.1)
        #expect(container.layer?.borderColor != nativeBorder)
    }

    // MARK: - The value inside the overlay

    private struct OverlayGrid {
        let window: NSWindow
        let tableView: KeyHandlingTableView
        let coordinator: TableViewCoordinator
    }

    /// A grid with one row, on `scope`, in a window an overlay can take first responder in.
    private func makeGrid(scope: ThemeScope) -> OverlayGrid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: OverlayLayoutPersister(),
            themeScope: scope
        )
        let tableRows = TableRows.from(
            queryRows: [[PluginCellValue.text("value")]],
            columns: ["name"],
            columnTypes: [ColumnType.text(rawType: "TEXT")]
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        tableView.rowHeight = 21
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: tableRows.columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 200 }
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        return OverlayGrid(window: window, tableView: tableView, coordinator: coordinator)
    }

    private func openEditor(on grid: OverlayGrid) throws -> (CellOverlayEditor, NSTextView) {
        let column = try #require(grid.coordinator.tableColumnIndex(forDisplayPosition: 0))
        let editor = CellOverlayEditor()
        editor.show(in: grid.tableView, row: 0, column: column, columnIndex: 0, value: "value")
        let container = try #require(editor.containerView)
        let scrollView = try #require(container.subviews.first as? NSScrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        return (editor, textView)
    }

    @Test("Under the default theme the inline editor keeps the system text colors")
    func overlayEditorDefaultIsNative() throws {
        let grid = makeGrid(scope: .fixed(BuiltInThemes.light))
        let (editor, textView) = try openEditor(on: grid)
        defer { editor.dismiss(commit: false) }

        #expect(textView.backgroundColor === NSColor.textBackgroundColor)
        #expect(textView.textColor === NSColor.labelColor)
        let aqua = try #require(NSAppearance(named: .aqua))
        #expect(ThemeTestFixture.hex(editor.containerView?.layer?.backgroundColor)
            == ThemeTestFixture.hex(ThemeTestFixture.baked(.textBackgroundColor, in: aqua)))
        withExtendedLifetime(grid.window) {}
    }

    /// The box used to be the system's text background with white text inside a theme's border, on
    /// a themed grid.
    @Test("Under a theme the inline editor and viewer take the editor's colors, through the grid's scope")
    func overlayTakesTheEditorColors() throws {
        var theme = try ThemeTestFixture.theme(.light, [
            .editorBackground: "#282A36",
            .editorText: "#F8F8F2",
            .editorCursor: "#FF79C6",
            .editorSelection: "#44475A",
        ])
        theme.id = "test.overlay-editor"
        let grid = makeGrid(scope: .fixed(theme))
        let (editor, textView) = try openEditor(on: grid)
        defer { editor.dismiss(commit: false) }

        #expect(ThemeTestFixture.hex(textView.backgroundColor) == "#282A36")
        #expect(ThemeTestFixture.hex(textView.textColor) == "#F8F8F2")
        #expect(ThemeTestFixture.hex(textView.insertionPointColor) == "#FF79C6")
        #expect(ThemeTestFixture.hex(textView.selectedTextAttributes[.backgroundColor] as? NSColor) == "#44475A")
        #expect(ThemeTestFixture.hex(editor.containerView?.layer?.backgroundColor) == "#282A36")
        #expect(ThemeTestFixture.hex((textView.enclosingScrollView?.backgroundColor)) == "#282A36")

        let viewer = CellOverlayViewer()
        let column = try #require(grid.coordinator.tableColumnIndex(forDisplayPosition: 0))
        viewer.show(in: grid.tableView, row: 0, column: column, columnIndex: 0, value: "value")
        defer { viewer.dismiss() }
        let viewerText = try #require(
            (viewer.containerView?.subviews.first as? NSScrollView)?.documentView as? NSTextView
        )
        #expect(ThemeTestFixture.hex(viewerText.backgroundColor) == "#282A36")
        #expect(ThemeTestFixture.hex(viewerText.textColor) == "#F8F8F2")
        withExtendedLifetime(grid.window) {}
    }
}
