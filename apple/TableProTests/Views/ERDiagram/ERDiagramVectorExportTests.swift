import AppKit
import PDFKit
@testable import TablePro
import Testing

@MainActor
struct ERDiagramVectorExportTests {
    private static let title = "shop.public"

    private func column(_ name: String, type: String = "integer", primaryKey: Bool = false, foreignKey: Bool = false) -> ERColumnDisplay {
        ERColumnDisplay(
            id: name,
            name: name,
            dataType: type,
            isPrimaryKey: primaryKey,
            isForeignKey: foreignKey,
            isNullable: false
        )
    }

    private func node(_ name: String, columns: [ERColumnDisplay]) -> ERTableNode {
        ERTableNode(id: UUID(), tableName: name, columns: columns, displayColumns: columns, clusterId: 0)
    }

    private func scene(usersName: String = "users", emailName: String = "email", selected: Bool = false) -> ERDiagramScene {
        let users = node(usersName, columns: [column("id", primaryKey: true), column(emailName, type: "text")])
        let orders = node("orders", columns: [column("id", primaryKey: true), column("user_id", foreignKey: true)])
        let width = ERDiagramLayout.nodeWidth
        let usersRect = CGRect(x: 120, y: 80, width: width, height: ERDiagramLayout.estimateHeight(columnCount: 2))
        let ordersRect = CGRect(x: 120 + width + 120, y: 80, width: width, height: ERDiagramLayout.estimateHeight(columnCount: 2))
        let edge = EREdge(
            id: UUID(),
            fkName: "orders_user_id_fkey",
            fromTable: "orders",
            fromColumn: "user_id",
            toTable: usersName,
            toColumn: "id",
            cardinality: .zeroOrManyToOne
        )
        return ERDiagramScene(
            nodes: [users, orders],
            edges: [edge],
            nodeRects: [users.id: usersRect, orders.id: ordersRect],
            nodeIndex: [usersName: users.id, "orders": orders.id],
            clusterColors: [users.id: .systemBlue, orders.id: .systemBlue],
            selectedNodeIds: selected ? [users.id] : [],
            size: CGSize(width: ordersRect.maxX + 80, height: ordersRect.maxY + 80)
        )
    }

    private func expectedSize(of scene: ERDiagramScene) -> CGSize {
        let bounds = ERDiagramSceneRenderer.drawnBounds(of: scene)
        let padding = ERDiagramSceneRenderer.exportPadding
        return CGSize(width: bounds.width + padding * 2, height: bounds.height + padding * 2)
    }

    private func appearance() throws -> NSAppearance {
        try #require(NSAppearance(named: .aqua))
    }

    private func svg(_ scene: ERDiagramScene) throws -> XMLElement {
        let text = ERDiagramSceneRenderer.svgDocument(scene, appearance: try appearance(), title: Self.title)
        let document = try XMLDocument(data: Data(text.utf8))
        return try #require(document.rootElement())
    }

    private func elements(named name: String, in root: XMLElement) -> [XMLElement] {
        let children = (root.children ?? []).compactMap { $0 as? XMLElement }
        return (root.localName == name ? [root] : []) + children.flatMap { elements(named: name, in: $0) }
    }

    // MARK: - PDF

    @Test("The PDF is one page sized like the PNG: what is drawn plus the export padding")
    func pdfIsOnePageSizedToTheDiagram() throws {
        let scene = scene()
        let data = try #require(ERDiagramSceneRenderer.pdfData(scene, appearance: try appearance(), title: Self.title))
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        let size = expectedSize(of: scene)

        #expect(document.pageCount == 1)
        #expect(abs(page.bounds(for: .mediaBox).width - size.width) < 0.5)
        #expect(abs(page.bounds(for: .mediaBox).height - size.height) < 0.5)
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == Self.title)
    }

    @Test("The PDF keeps table names, columns and types as text")
    func pdfKeepsTextAsText() throws {
        let data = try #require(ERDiagramSceneRenderer.pdfData(scene(), appearance: try appearance(), title: Self.title))
        let text = try #require(PDFDocument(data: data)?.page(at: 0)?.string)

        for word in ["users", "orders", "email", "user_id", "integer", "text"] {
            #expect(text.contains(word), "missing \(word)")
        }
    }

    @Test("A key badge draws upright in the flipped export, bow at the top as the SVG draws it")
    func symbolsDrawUpright() throws {
        let scale: CGFloat = 4
        let scene = scene()
        let image = try #require(ERDiagramSceneRenderer.image(scene, appearance: try appearance(), scale: scale))
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        let users = try #require(scene.nodes.first { $0.tableName == "users" })
        let rect = try #require(scene.nodeRects[users.id])
        let bounds = ERDiagramSceneRenderer.drawnBounds(of: scene)
        let padding = ERDiagramSceneRenderer.exportPadding
        let center = CGPoint(
            x: (rect.minX - bounds.minX + padding + 14 * ERDiagramLayout.typeScale) * scale,
            y: (rect.minY - bounds.minY + padding + ERDiagramLayout.headerHeight + ERDiagramLayout.columnRowHeight / 2) * scale
        )

        var upper = 0
        var lower = 0
        let reach = Int(8 * scale)
        for dy in -reach...reach {
            for dx in -reach...reach {
                guard let color = rep.colorAt(x: Int(center.x) + dx, y: Int(center.y) + dy)?.usingColorSpace(.sRGB),
                      color.redComponent > 0.7, color.greenComponent > 0.5, color.blueComponent < 0.4
                else { continue }
                if dy < 0 { upper += 1 } else if dy > 0 { lower += 1 }
            }
        }

        #expect(upper + lower > 0, "the key badge must be drawn")
        #expect(upper > lower)
    }

    // MARK: - SVG

    @Test("The SVG is well-formed and sized like the PNG")
    func svgIsSizedToTheDiagram() throws {
        let scene = scene()
        let root = try svg(scene)
        let size = expectedSize(of: scene)

        #expect(root.name == "svg")
        #expect(root.attribute(forName: "width")?.stringValue == ERDiagramSVGCanvas.number(size.width))
        #expect(root.attribute(forName: "height")?.stringValue == ERDiagramSVGCanvas.number(size.height))
        #expect(elements(named: "title", in: root).first?.stringValue == Self.title)
    }

    @Test("The SVG writes every table name, column and type as text")
    func svgKeepsTextAsText() throws {
        let texts = try elements(named: "text", in: svg(scene())).compactMap(\.stringValue)

        for word in ["users", "orders", "id", "email", "user_id", "integer", "text"] {
            #expect(texts.contains(word), "missing \(word)")
        }
        #expect(texts.count == 2 + 2 * 4)
    }

    @Test("The SVG draws an edge as its curve and the markers the canvas draws")
    func svgDrawsEdgeAndMarkers() throws {
        let paths = try elements(named: "path", in: svg(scene()))
        let connectors = paths.filter { $0.attribute(forName: "stroke-linecap")?.stringValue == "round" }

        // The curve, the crow's foot and circle at the foreign key, and the bar at the referenced end.
        #expect(connectors.count == 4)
        #expect(connectors.allSatisfy { $0.attribute(forName: "fill")?.stringValue == "none" })
    }

    @Test("The SVG embeds each symbol once and places it with a use")
    func svgSymbolsAreShared() throws {
        let root = try svg(scene())
        let images = elements(named: "image", in: root)
        let uses = elements(named: "use", in: root)

        // tablecells, key.fill and link; two table icons, two keys and one link.
        #expect(images.count == 3)
        #expect(uses.count == 5)
        #expect(images.allSatisfy { image in
            image.attribute(forLocalName: "href", uri: "http://www.w3.org/1999/xlink")?.stringValue?
                .hasPrefix("data:image/png;base64,") == true
        })
    }

    @Test("The export never shows the selection")
    func svgOmitsSelection() throws {
        let paths = try elements(named: "path", in: svg(scene(selected: true)))

        #expect(!paths.contains { $0.attribute(forName: "stroke-width")?.stringValue == "2" })
    }

    @Test("Names XML cannot hold as they are still give a well-formed file")
    func svgEscapesNames() throws {
        let texts = try elements(named: "text", in: svg(scene(usersName: "a&b<c>\"d", emailName: "e\u{1}f")))
            .compactMap(\.stringValue)

        #expect(texts.contains("a&b<c>\"d"))
        #expect(texts.contains("e\u{FFFD}f"))
    }

    @Test("A column name too long for its row ends in the same ellipsis the canvas draws")
    func svgTruncatesLikeTheCanvas() throws {
        let long = String(repeating: "shipping_address_", count: 4)
        let texts = try elements(named: "text", in: svg(scene(emailName: long))).compactMap(\.stringValue)
        let shown = try #require(texts.first { $0.hasPrefix("shipping_address_") })

        #expect(shown.hasSuffix("\u{2026}"))
        #expect(shown.count < long.count)
    }

    // MARK: - Encoding

    @Test("Text that fits is kept, and text that does not keeps the longest prefix that fits")
    func fittedText() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = "character varying(255)"
        let full = ERDiagramTextRenderer.width(of: text, font: font)
        let fitted = ERDiagramTextRenderer.fittedText(text, font: font, maxWidth: full / 2)
        let longer = String(text.prefix(fitted.count)) + "\u{2026}"

        #expect(ERDiagramTextRenderer.fittedText(text, font: font, maxWidth: full) == text)
        #expect(fitted.hasSuffix("\u{2026}"))
        #expect(ERDiagramTextRenderer.width(of: fitted, font: font) <= full / 2)
        #expect(ERDiagramTextRenderer.width(of: longer, font: font) > full / 2)
    }

    @Test("A path is written with SVG's commands")
    func pathData() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 10.5, y: 0))
        path.addCurve(to: CGPoint(x: 20, y: 5), control1: CGPoint(x: 12, y: 1), control2: CGPoint(x: 18.333, y: 4))
        path.closeSubpath()

        #expect(ERDiagramSVGCanvas.pathData(path) == "M0 0 L10.5 0 C12 1 18.33 4 20 5 Z")
    }

    @Test("Numbers are short and never negative zero", arguments: [
        (CGFloat(1), "1"), (1.5, "1.5"), (1.234, "1.23"), (-0.001, "0"), (120, "120"),
    ])
    func numbers(value: CGFloat, expected: String) {
        #expect(ERDiagramSVGCanvas.number(value) == expected)
    }

    @Test("A translucent color is written as a hex color and an opacity")
    func paint() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let color = try #require(CGColor(colorSpace: space, components: [1, 0.5, 0, 0.25]))

        #expect(ERDiagramSVGCanvas.paint("fill", color) == " fill=\"#FF8000\" fill-opacity=\"0.25\"")
    }
}
