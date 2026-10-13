//
//  ERDiagramThemeTests.swift
//  TableProTests
//
//  Tables on the ER canvas take the data grid's slots and the canvas takes the window background,
//  while the default pair draws exactly the system colors the diagram drew before themes reached it.
//  An export renders what the canvas shows.
//

import AppKit
@testable import TablePro
import Testing

/// A bitmap cache converts through its own color space, so a theme color is held to the same color
/// drawn by a plain fill into the same kind of cache.
@MainActor
private final class ThemeFillView: NSView {
    let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

@Suite("The ER diagram follows the theme", .serialized)
@MainActor
struct ERDiagramThemeTests {
    private typealias Fixture = DiagramThemeFixture

    private static let themed: [ThemeSlot: String] = [
        .windowBackdrop: "#1E2030",
        .gridBackground: "#2A6F4E",
        .gridHeaderBackground: "#7A3B8F",
        .gridHeaderText: "#F8F8F2",
        .gridText: "#E0E0E0",
        .gridLine: "#6272A4",
        .gridFocusBorder: "#FF79C6",
    ]

    private func appearance(_ name: NSAppearance.Name) throws -> NSAppearance {
        try #require(NSAppearance(named: name))
    }

    private func scene(clusterColor: NSColor? = nil) -> (ERDiagramScene, CGRect) {
        let node = ERTableNode(id: UUID(), tableName: "t", columns: [], displayColumns: [], clusterId: nil)
        let rect = CGRect(
            x: 0, y: 0,
            width: ERDiagramLayout.nodeWidth,
            height: ERDiagramLayout.estimateHeight(columnCount: 3)
        )
        let scene = ERDiagramScene(
            nodes: [node],
            edges: [],
            nodeRects: [node.id: rect],
            nodeIndex: [node.tableName: node.id],
            clusterColors: clusterColor.map { [node.id: $0] } ?? [:],
            selectedNodeId: nil,
            size: CGSize(width: rect.maxX + 20, height: rect.maxY + 20)
        )
        return (scene, rect)
    }

    // MARK: - Palette

    @Test("Under the default pair a table draws the system colors it always has", arguments: [
        NSAppearance.Name.aqua, .darkAqua,
    ])
    func defaultPairDrawsSystemColors(_ name: NSAppearance.Name) throws {
        try Fixture.preservingEngine {
            try Fixture.adopt([:])
            let appearance = try appearance(name)
            let palette = ERDiagramPalette(appearance: appearance)

            #expect(palette.backdrop == Fixture.baked(.controlBackgroundColor, in: appearance))
            #expect(palette.nodeFill == Fixture.baked(.controlBackgroundColor, in: appearance))
            #expect(palette.headerFill == nil)
            #expect(palette.headerWash(cluster: nil) == mainAccentWash(in: appearance))
            #expect(palette.headerWash(cluster: .systemGreen) == mainClusterWash(.systemGreen, in: appearance))
            #expect(palette.rule == Fixture.baked(.tertiaryLabelColor, in: appearance))
            #expect(palette.selectionRule == Fixture.baked(.controlAccentColor, in: appearance))
            #expect(palette.edge == mainEdge(in: appearance))
            #expect(palette.text == .labelColor)
            #expect(palette.headerText == .labelColor)
            #expect(palette.secondaryText == .secondaryLabelColor)
        }
    }

    @Test("A theme colors the tables from the grid's slots and keeps meaning hues and connectors system")
    func themeColorsTablesFromGridSlots() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt(Self.themed)
            let appearance = try appearance(.aqua)
            let palette = ERDiagramPalette(appearance: appearance)

            #expect(Fixture.hex(palette.backdrop) == "#1E2030")
            #expect(Fixture.hex(palette.nodeFill) == "#2A6F4E")
            #expect(Fixture.hex(palette.headerFill) == "#7A3B8F")
            #expect(Fixture.hex(palette.rule) == "#6272A4")
            #expect(Fixture.hex(palette.selectionRule) == "#FF79C6")
            #expect(HexColor.string(from: palette.text) == "#E0E0E0")
            #expect(HexColor.string(from: palette.headerText) == "#F8F8F2")
            #expect(palette.secondaryText == .secondaryLabelColor)
            #expect(palette.edge == mainEdge(in: appearance))
            #expect(palette.headerWash(cluster: .systemGreen) == mainClusterWash(.systemGreen, in: appearance))
        }
    }

    @Test("A canvas bakes the theme of its own appearance, not the active one")
    func paletteFollowsTheCanvasAppearance() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt(Self.themed, appearance: .dark)
            let light = try appearance(.aqua)
            let dark = try appearance(.darkAqua)

            #expect(Fixture.hex(ERDiagramPalette(appearance: dark).nodeFill) == "#2A6F4E")
            #expect(Fixture.hex(ERDiagramPalette(appearance: dark).backdrop) == "#1E2030")
            #expect(ERDiagramPalette(appearance: light).nodeFill == Fixture.baked(.controlBackgroundColor, in: light))
            #expect(ERDiagramPalette(appearance: light).backdrop == Fixture.baked(.controlBackgroundColor, in: light))
        }
    }

    // MARK: - What main drew, evaluated inside the appearance as its `draw` did

    private func mainAccentWash(in appearance: NSAppearance) -> CGColor {
        Fixture.resolved(in: appearance) { NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor }
    }

    private func mainClusterWash(_ cluster: NSColor, in appearance: NSAppearance) -> CGColor {
        Fixture.resolved(in: appearance) { cluster.withAlphaComponent(0.22).cgColor }
    }

    private func mainEdge(in appearance: NSAppearance) -> CGColor {
        Fixture.resolved(in: appearance) { NSColor.secondaryLabelColor.withAlphaComponent(0.7).cgColor }
    }

    // MARK: - Canvas

    @Test("The canvas re-bakes its colors when the theme changes")
    func sceneViewRebakesOnThemeChange() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt([:])
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let view = ERDiagramSceneView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            view.appearance = try appearance(.aqua)
            window.contentView = view
            let before = view.palette.nodeFill
            view.needsDisplay = false

            try Fixture.adopt(Self.themed)

            #expect(view.needsDisplay)
            #expect(Fixture.hex(view.palette.nodeFill) == "#2A6F4E")
            #expect(view.palette.nodeFill != before)
            window.contentView = nil
        }
    }

    @Test("The canvas draws a table in the theme's grid background")
    func sceneViewDrawsThemedTable() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt(Self.themed)
            let (scene, rect) = scene()
            let view = ERDiagramSceneView(frame: NSRect(origin: .zero, size: scene.size))
            view.appearance = try appearance(.aqua)
            view.scene = scene

            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let reference = ThemeFillView(color: HexColor.color("#2A6F4E"))
            reference.appearance = view.appearance
            let referenceRep = try #require(reference.bitmapImageRepForCachingDisplay(in: reference.bounds))
            reference.cacheDisplay(in: reference.bounds, to: referenceRep)

            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let body = try #require(Fixture.pixel(
                rep, x: Int((rect.maxX - 20) * scale), y: Int((rect.maxY - 10) * scale)
            ))
            let expected = try #require(Fixture.pixel(referenceRep, x: referenceRep.pixelsWide / 2, y: referenceRep.pixelsHigh / 2))
            #expect(Fixture.matches(body, expected), "drew \(body), theme \(expected)")
        }
    }

    @Test("A theme's window background fills the canvas, and only while the theme sets it")
    func canvasBackdropFollowsTheTheme() throws {
        try Fixture.preservingEngine {
            try Fixture.adopt([:])
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            scrollView.appearance = try appearance(.aqua)
            scrollView.drawsBackground = false
            let original = scrollView.backgroundColor
            let backdrop = DiagramCanvasBackdrop(scrollView: scrollView)

            #expect(!scrollView.drawsBackground)
            #expect(!backdrop.isThemed)

            try Fixture.adopt(Self.themed)
            #expect(scrollView.drawsBackground)
            #expect(Fixture.hex(Fixture.baked(scrollView.backgroundColor, in: try appearance(.aqua))) == "#1E2030")
            #expect(backdrop.isThemed)

            try Fixture.adopt([:])
            #expect(!scrollView.drawsBackground)
            #expect(scrollView.backgroundColor == original)
            withExtendedLifetime(backdrop) {}
        }
    }

    // MARK: - Export

    @Test("An export takes the canvas's appearance rather than one built from the color scheme")
    func exportAppearanceIsTheCanvas() throws {
        let controller = DiagramViewportController()
        let scrollView = DiagramScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.appearance = try appearance(.darkAqua)
        controller.attach(to: scrollView)

        #expect(controller.effectiveAppearance.name == scrollView.effectiveAppearance.name)
        #expect(controller.effectiveAppearance.isDarkTheme)

        scrollView.appearance = try appearance(.aqua)
        #expect(!controller.effectiveAppearance.isDarkTheme)
        controller.detach(from: scrollView)
    }

    @Test("An export fills what the canvas shows: system colors by default, the theme's under one", arguments: [
        false, true,
    ])
    func exportRendersWhatTheCanvasShows(themed: Bool) throws {
        try Fixture.preservingEngine {
            try Fixture.adopt(themed ? Self.themed : [:])
            let appearance = try appearance(.aqua)
            let palette = ERDiagramPalette(appearance: appearance)
            let (scene, rect) = scene()
            let image = try #require(ERDiagramSceneRenderer.image(scene, appearance: appearance, scale: 1))
            let rep = try #require(image.representations.first as? NSBitmapImageRep)
            let padding = Int(ERDiagramSceneRenderer.exportPadding)

            let backdrop = try #require(Fixture.pixel(rep, x: 4, y: 4))
            let body = try #require(Fixture.pixel(rep, x: padding + Int(rect.maxX) - 20, y: padding + Int(rect.maxY) - 10))
            let header = try #require(Fixture.pixel(
                rep, x: padding + Int(rect.maxX) - 20, y: padding + Int(ERDiagramLayout.headerHeight / 2)
            ))

            #expect(Fixture.matches(backdrop, try reference(palette.backdrop)))
            #expect(Fixture.matches(body, try reference(palette.nodeFill)))
            if themed {
                #expect(Fixture.hex(palette.backdrop) == "#1E2030")
                #expect(Fixture.matches(header, try reference(try #require(palette.headerFill))))
            } else {
                #expect(palette.backdrop == Fixture.baked(.controlBackgroundColor, in: appearance))
                #expect(!Fixture.matches(header, try reference(palette.nodeFill)))
            }
        }
    }

    /// Filled into the same kind of bitmap the export draws into, so the conversion cancels out.
    private func reference(_ color: CGColor) throws -> NSColor {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try #require(Fixture.pixel(rep, x: 1, y: 1))
    }
}
