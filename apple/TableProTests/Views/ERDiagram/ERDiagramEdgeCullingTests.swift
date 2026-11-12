import AppKit
@testable import TablePro
import Testing

@MainActor
struct ERDiagramEdgeCullingTests {
    @MainActor
    private final class StrokeRecorder: ERDiagramCanvas {
        private(set) var strokedBounds: [CGRect] = []

        func fill(_ path: CGPath, color: CGColor) {}

        func stroke(_ path: CGPath, color: CGColor, lineWidth: CGFloat, rounded: Bool) {
            strokedBounds.append(path.boundingBoxOfPath)
        }

        func clip(to path: CGPath, _ draw: () -> Void) {
            draw()
        }

        func drawText(
            _ text: String,
            font: NSFont,
            color: NSColor,
            at point: CGPoint,
            anchor: ERDiagramTextAnchor,
            maxWidth: CGFloat
        ) {}

        func drawSymbol(named name: String, pointSize: CGFloat, color: NSColor, at point: CGPoint, anchor: ERDiagramTextAnchor) {}
    }

    private static let colors = ERDiagramEdgeRenderer.Colors(
        stroke: NSColor.gray.cgColor,
        selection: NSColor.blue.cgColor,
        dropped: NSColor.red.cgColor
    )

    private static func edge(_ from: String, _ to: String) -> EREdge {
        EREdge(
            id: UUID(),
            fkName: "fk_\(from)_\(to)",
            fromTable: from,
            fromColumn: "\(to)_id",
            toTable: to,
            toColumn: "id",
            cardinality: .manyToOne
        )
    }

    private static let rects: [String: CGRect] = [
        "a": CGRect(x: 40, y: 40, width: 220, height: 80),
        "b": CGRect(x: 40, y: 300, width: 220, height: 80),
        "c": CGRect(x: 3_000, y: 40, width: 220, height: 80),
        "d": CGRect(x: 3_000, y: 300, width: 220, height: 80),
    ]

    private func strokes(of edges: [EREdge], in dirtyRect: CGRect) -> [CGRect] {
        var index: [String: UUID] = [:]
        var nodeRects: [UUID: CGRect] = [:]
        for (name, rect) in Self.rects {
            let id = UUID()
            index[name] = id
            nodeRects[id] = rect
        }
        let recorder = StrokeRecorder()
        ERDiagramEdgeRenderer.drawRoutes(
            ERDiagramEdgeRenderer.routes(edges: edges, nodeRects: nodeRects, nodeIndex: index),
            colors: Self.colors,
            selectedEdgeId: nil,
            dirtyRect: dirtyRect,
            on: recorder
        )
        return recorder.strokedBounds
    }

    @Test("Only the edges that cross the drawn rect are stroked")
    func strokesOnlyEdgesInTheDirtyRect() {
        let edges = [Self.edge("a", "b"), Self.edge("c", "d")]
        let everything = strokes(of: edges, in: .infinite)
        let left = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let culled = strokes(of: edges, in: left)

        #expect(!culled.isEmpty)
        #expect(culled.count * 2 == everything.count)
        #expect(culled.allSatisfy { $0.insetBy(dx: -3, dy: -3).intersects(left) })
    }

    @Test("An edge whose tables are both outside the drawn rect still draws where it crosses it")
    func strokesAnEdgePassingThrough() {
        let middle = CGRect(x: 1_000, y: 0, width: 400, height: 1_000)
        #expect(!strokes(of: [Self.edge("a", "c")], in: middle).isEmpty)
        #expect(strokes(of: [Self.edge("a", "b")], in: middle).isEmpty)
    }
}
