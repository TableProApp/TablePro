//
//  ERDiagramScene.swift
//  TablePro
//
//  Everything the diagram needs to paint one frame, and the two ways it is painted: into a view
//  and into an export bitmap. One renderer serves both, so an exported PNG cannot drift from
//  what is on screen.
//

import AppKit

struct ERDiagramScene {
    var nodes: [ERTableNode] = []
    var edges: [EREdge] = []
    var nodeRects: [UUID: CGRect] = [:]
    var nodeIndex: [String: UUID] = [:]
    var clusterColors: [UUID: NSColor] = [:]
    var selectedNodeId: UUID?
    var size = CGSize(width: 800, height: 600)
}

@MainActor
enum ERDiagramSceneRenderer {
    static let exportPadding: CGFloat = 40

    /// Everything the scene puts on the canvas, which is more than the tables: a self-referencing
    /// table loops out past its own trailing edge, and cropping the export to the table rects alone
    /// cuts the apex off.
    static func drawnBounds(of scene: ERDiagramScene) -> CGRect {
        var bounds = scene.nodeRects.values.reduce(CGRect.null) { $0.union($1) }

        var selfLoopIndex: [UUID: Int] = [:]
        for edge in scene.edges where edge.fromTable == edge.toTable {
            guard let nodeId = scene.nodeIndex[edge.fromTable], let rect = scene.nodeRects[nodeId] else { continue }
            let index = selfLoopIndex[nodeId, default: 0]
            selfLoopIndex[nodeId] = index + 1
            bounds = bounds.union(ERDiagramEdgeRenderer.selfLoopBounds(in: rect, index: index))
        }
        return bounds
    }

    /// The context is expected to be flipped, which is what both callers hand it: the diagram view
    /// is `isFlipped`, and the export builds a flipped `NSGraphicsContext` over its bitmap.
    static func draw(_ scene: ERDiagramScene, dirtyRect: CGRect, in context: CGContext) {
        ERDiagramEdgeRenderer.drawEdges(
            edges: scene.edges,
            nodeRects: scene.nodeRects,
            nodeIndex: scene.nodeIndex,
            in: context
        )

        for node in scene.nodes {
            guard let rect = scene.nodeRects[node.id], rect.intersects(dirtyRect) else { continue }
            ERDiagramNodeRenderer.drawNode(
                node: node,
                rect: rect,
                isSelected: scene.selectedNodeId == node.id,
                clusterColor: scene.clusterColors[node.id],
                in: context
            )
        }
    }

    /// Renders at natural scale whatever the viewport is doing, cropped to the nodes rather than to
    /// the canvas, which is what the export has always promised.
    ///
    /// `NSColor` resolves against the appearance that is current while drawing, and an offscreen
    /// bitmap has none of its own, so the caller's appearance is made current for the whole render
    /// or a dark window exports light chrome.
    static func image(_ scene: ERDiagramScene, appearance: NSAppearance, scale: CGFloat) -> NSImage? {
        let bounds = drawnBounds(of: scene)
        let size = bounds.isNull
            ? CGSize(width: 100, height: 100)
            : CGSize(width: bounds.width + exportPadding * 2, height: bounds.height + exportPadding * 2)
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cgContext = base.cgContext

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        cgContext.translateBy(x: 0, y: size.height)
        cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: true)

        appearance.performAsCurrentDrawingAppearance {
            cgContext.setFillColor(NSColor.controlBackgroundColor.cgColor)
            cgContext.fill(CGRect(origin: .zero, size: size))

            cgContext.saveGState()
            if !bounds.isNull {
                cgContext.translateBy(x: -bounds.minX + exportPadding, y: -bounds.minY + exportPadding)
            }
            var flat = scene
            flat.selectedNodeId = nil
            draw(flat, dirtyRect: bounds.isNull ? .infinite : bounds, in: cgContext)
            cgContext.restoreGState()
        }

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
