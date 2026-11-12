import AppKit
@testable import TablePro
import Testing

@MainActor
struct ERDiagramBitmapExportTests {
    private func scene(tablesAt origins: [CGPoint]) -> ERDiagramScene {
        let columns = [ERColumnDisplay(id: "id", name: "id", dataType: "integer", isPrimaryKey: true, isForeignKey: false, isNullable: false)]
        var nodes: [ERTableNode] = []
        var rects: [UUID: CGRect] = [:]
        var index: [String: UUID] = [:]
        for (offset, origin) in origins.enumerated() {
            let node = ERTableNode(id: UUID(), tableName: "t\(offset)", columns: columns, displayColumns: columns, clusterId: 0)
            nodes.append(node)
            rects[node.id] = CGRect(
                origin: origin,
                size: CGSize(width: ERDiagramLayout.nodeWidth, height: ERDiagramLayout.estimateHeight(columnCount: 1))
            )
            index[node.tableName] = node.id
        }
        return ERDiagramScene(nodes: nodes, edges: [], nodeRects: rects, nodeIndex: index)
    }

    private func pixels(of image: NSImage?) throws -> (wide: Int, high: Int) {
        let rep = try #require(image?.representations.first as? NSBitmapImageRep)
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    private func appearance() throws -> NSAppearance {
        try #require(NSAppearance(named: .aqua))
    }

    @Test("A small diagram still renders at twice its size")
    func smallDiagramKeepsTheRequestedScale() throws {
        let small = scene(tablesAt: [.zero, CGPoint(x: 400, y: 0)])
        let image = ERDiagramSceneRenderer.image(small, appearance: try appearance(), scale: 2)
        let size = try #require(image?.size)

        let rendered = try pixels(of: image)
        #expect(rendered.wide == Int((size.width * 2).rounded(.down)))
        #expect(rendered.high == Int((size.height * 2).rounded(.down)))
    }

    @Test("A diagram wider than the side limit renders within it")
    func wideDiagramStaysWithinTheSideLimit() throws {
        let wide = scene(tablesAt: [.zero, CGPoint(x: 20_000, y: 0)])

        let rendered = try pixels(of: ERDiagramSceneRenderer.image(wide, appearance: try appearance(), scale: 2))

        #expect(CGFloat(rendered.wide) <= ERDiagramSceneRenderer.maxBitmapSide)
        #expect(rendered.wide > 16_000)
    }

    @Test("A diagram of hundreds of tables is scaled to the pixel budget, never past the requested scale")
    func largeDiagramStaysWithinThePixelBudget() {
        let size = CGSize(width: 7_500, height: 7_600)
        let scale = ERDiagramSceneRenderer.bitmapScale(for: size, requested: 2)

        let wide = (size.width * scale).rounded(.down)
        let high = (size.height * scale).rounded(.down)
        #expect(scale < 2)
        #expect(wide * high <= ERDiagramSceneRenderer.maxBitmapPixels)
        #expect(max(wide, high) <= ERDiagramSceneRenderer.maxBitmapSide)
        #expect(ERDiagramSceneRenderer.bitmapScale(for: CGSize(width: 800, height: 600), requested: 2) == 2)
    }

    @Test("PNG export encodes the capped bitmap")
    func pngExportIsCapped() throws {
        let wide = scene(tablesAt: [.zero, CGPoint(x: 20_000, y: 0)])
        let data = try #require(ERDiagramSceneRenderer.pngData(wide, appearance: try appearance(), scale: 2))
        let rep = try #require(NSBitmapImageRep(data: data))

        #expect(CGFloat(rep.pixelsWide) <= ERDiagramSceneRenderer.maxBitmapSide)
    }
}
