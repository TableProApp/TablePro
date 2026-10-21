import AppKit

struct ERDiagramScene {
    var nodes: [ERTableNode] = []
    var edges: [EREdge] = []
    var nodeRects: [UUID: CGRect] = [:]
    var nodeIndex: [String: UUID] = [:]
    var clusterColors: [UUID: NSColor] = [:]
    var selectedNodeId: UUID?
    var selectedEdgeId: UUID?
    var size = CGSize(width: 800, height: 600)
}

@MainActor
enum ERDiagramSceneRenderer {
    static let exportPadding: CGFloat = 40

    // A self-referencing table loops out past its trailing edge.
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

    static func draw(_ scene: ERDiagramScene, palette: ERDiagramPalette, dirtyRect: CGRect, on canvas: some ERDiagramCanvas) {
        ERDiagramEdgeRenderer.drawEdges(
            edges: scene.edges,
            nodeRects: scene.nodeRects,
            nodeIndex: scene.nodeIndex,
            colors: ERDiagramEdgeRenderer.Colors(
                stroke: palette.edge,
                selection: palette.selectionRule,
                dropped: palette.droppedEdge
            ),
            selectedEdgeId: scene.selectedEdgeId,
            on: canvas
        )

        for node in scene.nodes {
            guard let rect = scene.nodeRects[node.id], rect.intersects(dirtyRect) else { continue }
            ERDiagramNodeRenderer.drawNode(
                node: node,
                rect: rect,
                isSelected: scene.selectedNodeId == node.id,
                clusterColor: scene.clusterColors[node.id],
                palette: palette,
                on: canvas
            )
        }
    }

    // MARK: - Exports

    private struct ExportFrame {
        let size: CGSize
        let origin: CGPoint
        let dirtyRect: CGRect
    }

    private static func exportFrame(of scene: ERDiagramScene) -> ExportFrame {
        let bounds = drawnBounds(of: scene)
        guard !bounds.isNull else {
            return ExportFrame(size: CGSize(width: 100, height: 100), origin: .zero, dirtyRect: .infinite)
        }
        return ExportFrame(
            size: CGSize(width: bounds.width + exportPadding * 2, height: bounds.height + exportPadding * 2),
            origin: CGPoint(x: exportPadding - bounds.minX, y: exportPadding - bounds.minY),
            dirtyRect: bounds
        )
    }

    private static func unselected(_ scene: ERDiagramScene) -> ERDiagramScene {
        var flat = scene
        flat.selectedNodeId = nil
        flat.selectedEdgeId = nil
        return flat
    }

    // An offscreen context has no appearance, so the canvas's is made current for the whole render.
    private static func renderExport(
        _ scene: ERDiagramScene,
        frame: ExportFrame,
        appearance: NSAppearance,
        into cgContext: CGContext
    ) {
        cgContext.translateBy(x: 0, y: frame.size.height)
        cgContext.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: true)

        let palette = ERDiagramPalette(appearance: appearance)
        let canvas = ERDiagramContextCanvas(context: cgContext)
        appearance.performAsCurrentDrawingAppearance {
            canvas.fill(CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil), color: palette.backdrop)

            cgContext.saveGState()
            cgContext.translateBy(x: frame.origin.x, y: frame.origin.y)
            draw(unselected(scene), palette: palette, dirtyRect: frame.dirtyRect, on: canvas)
            cgContext.restoreGState()
        }
    }

    static func image(_ scene: ERDiagramScene, appearance: NSAppearance, scale: CGFloat) -> NSImage? {
        let frame = exportFrame(of: scene)
        let pixelsWide = Int((frame.size.width * scale).rounded())
        let pixelsHigh = Int((frame.size.height * scale).rounded())
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
        rep.size = frame.size

        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        renderExport(scene, frame: frame, appearance: appearance, into: base.cgContext)

        let image = NSImage(size: frame.size)
        image.addRepresentation(rep)
        return image
    }

    static func pdfData(_ scene: ERDiagramScene, appearance: NSAppearance, title: String) -> Data? {
        let frame = exportFrame(of: scene)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: frame.size)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextCreator: "TablePro",
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return nil }

        context.beginPDFPage(nil)
        context.saveGState()
        renderExport(scene, frame: frame, appearance: appearance, into: context)
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func svgDocument(_ scene: ERDiagramScene, appearance: NSAppearance, title: String) -> String {
        let frame = exportFrame(of: scene)
        let palette = ERDiagramPalette(appearance: appearance)
        let canvas = ERDiagramSVGCanvas()
        appearance.performAsCurrentDrawingAppearance {
            canvas.fill(CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil), color: palette.backdrop)
            canvas.translated(by: frame.origin) {
                draw(unselected(scene), palette: palette, dirtyRect: frame.dirtyRect, on: canvas)
            }
        }
        return canvas.document(size: frame.size, title: title)
    }
}
