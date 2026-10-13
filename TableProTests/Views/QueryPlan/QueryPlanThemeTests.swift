//
//  QueryPlanThemeTests.swift
//  TableProTests
//
//  The plan outline is a records table whose rows stay AppKit's own until a theme draws them, its
//  detail pane and the diagram's steps sit on the grid's slots, and an export renders the scheme and
//  the backdrop the canvas shows.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@Suite("The query plan follows the theme", .serialized)
@MainActor
struct QueryPlanThemeTests {
    private typealias Fixture = ThemeTestFixture

    private func node(_ operation: String, children: [QueryPlanNode] = []) -> QueryPlanNode {
        QueryPlanNode(
            operation: operation,
            relation: nil, schema: nil, alias: nil,
            estimatedStartupCost: nil,
            estimatedTotalCost: 10,
            estimatedRows: 5,
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: nil,
            actualRows: nil,
            actualLoops: nil,
            properties: [:],
            children: children
        )
    }

    private func plan() -> QueryPlan {
        var plan = QueryPlan(
            rootNode: node("Hash Join", children: [node("Seq Scan"), node("Index Scan")]),
            planningTime: nil,
            executionTime: nil,
            rawText: ""
        )
        plan.computeCostFractions()
        return plan
    }

    private func outlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let found = outlineView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Outline

    private struct MountedOutline {
        let window: NSWindow
        let outline: NSOutlineView
        let coordinator: QueryPlanOutlineCoordinator
    }

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    private func mountOutline() throws -> MountedOutline {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: QueryPlanOutlineView(plan: plan(), metric: nil, selectedNodeId: .constant(nil)))
        host.sizingOptions = []
        window.contentView = host
        for _ in 0 ..< 5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        let outline = try #require(outlineView(in: host))
        let coordinator = try #require(outline.delegate as? QueryPlanOutlineCoordinator)
        return MountedOutline(window: window, outline: outline, coordinator: coordinator)
    }

    @Test("Under the default pair the outline's rows are AppKit's own row view, and its cells are records cells")
    func outlineRowsAreNativeByDefault() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt([:], appearance: .light)
            let mounted = try mountOutline()
            let chrome = try #require(mounted.coordinator.themeChrome)
            #expect(chrome.family == .records)

            let root = try #require(mounted.coordinator.root)
            #expect(mounted.coordinator.outlineView(mounted.outline, rowViewForItem: root) == nil)
            #expect(mounted.outline.numberOfRows == 3)
            for row in 0 ..< mounted.outline.numberOfRows {
                let rowView = try #require(mounted.outline.rowView(atRow: row, makeIfNecessary: true))
                #expect(type(of: rowView) == NSTableRowView.self)
                #expect(mounted.outline.view(atColumn: 0, row: row, makeIfNecessary: true) is ThemeTableChrome.HostingCell)
            }
            mounted.window.contentView = nil
        }
    }

    @Test("A theme's selection swaps in themed rows, tells the selected row's cells, and a default theme swaps back")
    func outlineRowClassFollowsTheTheme() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt([:], appearance: .light)
            let mounted = try mountOutline()
            let chrome = try #require(mounted.coordinator.themeChrome)
            #expect(mounted.outline.selectedRowIndexes == IndexSet(integer: 0))
            _ = try #require(mounted.outline.rowView(atRow: 0, makeIfNecessary: true))

            var selections: [UUID?] = []
            mounted.coordinator.onSelect = { selections.append($0) }

            try Fixture.adopt([.gridSelection: "#2A6F4E", .gridSelectionText: "#FFFFFF"], appearance: .light)
            let themed = try #require(mounted.outline.rowView(atRow: 0, makeIfNecessary: true) as? ThemeTableRowView)
            #expect(themed.chrome === chrome)
            #expect(mounted.outline.selectedRowIndexes == IndexSet(integer: 0))
            #expect(mounted.outline.isItemExpanded(try #require(mounted.coordinator.root)))
            themed.isEmphasized = true
            let cell = try #require(mounted.outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThemeTableChrome.HostingCell)
            #expect(cell.isOnThemedSelection)

            try Fixture.adopt([:], appearance: .light)
            let native = try #require(mounted.outline.rowView(atRow: 0, makeIfNecessary: true))
            #expect(type(of: native) == NSTableRowView.self)
            #expect(mounted.outline.selectedRowIndexes == IndexSet(integer: 0))
            #expect(mounted.outline.numberOfRows == 3)
            #expect(selections.isEmpty, "the rebuild reported \(selections.count) selection changes")
            mounted.window.contentView = nil
        }
    }

    @Test("Under the default pair the outline stays AppKit's; under a theme it takes the grid's colors")
    func outlineFollowsTheGridSlots() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt([:], appearance: .light)
            let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            outline.usesAlternatingRowBackgroundColors = true
            let scrollView = NSScrollView(frame: outline.frame)
            scrollView.documentView = outline
            let background = outline.backgroundColor
            let coordinator = QueryPlanOutlineCoordinator()
            coordinator.attachThemeChrome(to: outline)

            #expect(outline.backgroundColor === background)
            #expect(outline.usesAlternatingRowBackgroundColors)

            try Fixture.adopt([.gridBackground: "#2A6F4E", .gridLine: "#6272A4"], appearance: .light)
            let aqua = try #require(NSAppearance(named: .aqua))
            #expect(Fixture.hex(Fixture.baked(outline.backgroundColor, in: aqua)) == "#2A6F4E")
            #expect(Fixture.hex(Fixture.baked(outline.gridColor, in: aqua)) == "#6272A4")

            try Fixture.adopt([:], appearance: .light)
            #expect(outline.backgroundColor == background)
        }
    }

    // MARK: - Detail pane

    @Test("The detail pane fills with the grid background, and its system color by default")
    func detailPaneTakesTheGridBackground() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt([:], appearance: .light)
            let pane = QueryPlanDetailPane(node: nil).frame(width: 240, height: 160)
            let native = try #require(Fixture.render(pane, colorScheme: .light))
            let nativeReference = try Fixture.filled(.controlBackgroundColor, colorScheme: .light)
            #expect(Fixture.matches(try #require(Fixture.pixel(native, x: 4, y: 4)), nativeReference))

            try Fixture.adopt([.gridBackground: "#2A6F4E"], appearance: .light)
            let themed = try #require(Fixture.render(pane, colorScheme: .light))
            let themedReference = try Fixture.filled(hex: "#2A6F4E", colorScheme: .light)
            #expect(Fixture.matches(try #require(Fixture.pixel(themed, x: 4, y: 4)), themedReference))
        }
    }

    // MARK: - Diagram

    @Test("A step sits on the grid background under a theme, and on nothing extra by default")
    func diagramStepTakesTheGridBackground() throws {
        try Fixture.preservingEngine {
            let step = QueryPlanDiagramNodeView(node: node("Seq Scan"), isSelected: false)
            let themeColor = try Fixture.filled(hex: "#2A6F4E", colorScheme: .light)

            try Fixture.adopt([:], appearance: .light)
            let native = try #require(Fixture.render(step, colorScheme: .light))
            let nativeInterior = try #require(Fixture.pixel(native, x: native.pixelsWide - 6, y: native.pixelsHigh / 2))
            #expect(!Fixture.matches(nativeInterior, themeColor, tolerance: 0.1))
            #expect(nativeInterior.alphaComponent < 0.5)

            try Fixture.adopt([.gridBackground: "#2A6F4E"], appearance: .light)
            let themed = try #require(Fixture.render(step, colorScheme: .light))
            let themedInterior = try #require(Fixture.pixel(themed, x: themed.pixelsWide - 6, y: themed.pixelsHigh / 2))
            #expect(Fixture.matches(themedInterior, themeColor, tolerance: 0.1), "drew \(themedInterior)")
        }
    }

    @Test("An export renders in the canvas's scheme, on the system color by default", arguments: [
        ColorScheme.light, .dark,
    ])
    func exportUsesTheCanvasScheme(_ colorScheme: ColorScheme) throws {
        try Fixture.preservingEngine {
            try Fixture.adopt([:], appearance: .light)
            let canvas = QueryPlanDiagramExportCanvas(
                layout: QueryPlanDiagramLayout(root: plan().rootNode),
                colorScheme: colorScheme
            )
            let rep = try #require(Fixture.render(canvas, colorScheme: .light))
            let reference = try Fixture.filled(.controlBackgroundColor, colorScheme: colorScheme)
            #expect(Fixture.matches(try #require(Fixture.pixel(rep, x: 2, y: 2)), reference))
        }
    }

    @Test("An export fills the theme's window background")
    func exportFillsTheWindowBackground() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt([.windowBackdrop: "#1E2030"], appearance: .dark)
            let canvas = QueryPlanDiagramExportCanvas(layout: QueryPlanDiagramLayout(root: plan().rootNode), colorScheme: .dark)
            let rep = try #require(Fixture.render(canvas, colorScheme: .light))
            let reference = try Fixture.filled(hex: "#1E2030", colorScheme: .dark)
            #expect(Fixture.matches(try #require(Fixture.pixel(rep, x: 2, y: 2)), reference))
        }
    }
}
