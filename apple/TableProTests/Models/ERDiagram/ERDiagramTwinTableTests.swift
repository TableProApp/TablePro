import Foundation
@testable import TablePro
import Testing

struct ERDiagramTwinTableTests {
    private static let composed = CatalogName(TwinNames.composed)
    private static let decomposed = CatalogName(TwinNames.decomposed)

    private static func column(_ name: String, primaryKey: Bool = false) -> ColumnInfo {
        ColumnInfo(name: name, dataType: "integer", isNullable: false, isPrimaryKey: primaryKey)
    }

    private static func twinGraph() -> ERDiagramGraph {
        ERDiagramGraphBuilder.build(
            allColumns: [
                composed: [column("id", primaryKey: true), column("a")],
                decomposed: [column("id", primaryKey: true), column("b")],
                "child": [column("id", primaryKey: true), column("parent_id")]
            ],
            allForeignKeys: [
                "child": [ForeignKeyInfo(
                    name: "child_parent", column: "parent_id", referencedTable: TwinNames.decomposed, referencedColumn: "id"
                )]
            ]
        )
    }

    @Test("Two tables whose names differ only in Unicode form are two nodes with their own columns")
    func twinsAreTwoNodes() {
        let graph = Self.twinGraph()
        let composedNode = graph.nodes.first { $0.id == graph.nodeIndex[Self.composed] }
        let decomposedNode = graph.nodes.first { $0.id == graph.nodeIndex[Self.decomposed] }

        #expect(graph.nodes.count == 3)
        #expect(composedNode?.columns.map(\.name) == ["id", "a"])
        #expect(decomposedNode?.columns.map(\.name) == ["id", "b"])
    }

    @Test("A key to one twin draws its edge to that twin")
    func edgeReachesTheNamedTwin() {
        let graph = Self.twinGraph()

        #expect(graph.edges.count == 1)
        #expect(graph.edges.first.flatMap { graph.nodeId(of: $0.toTable) } == graph.nodeIndex[Self.decomposed])
        #expect(graph.nodeIndex[Self.composed] != graph.nodeIndex[Self.decomposed])
    }

    @Test("A staged edit on one twin draws on that twin only")
    func stagedEditStaysOnItsTwin() {
        let edits = ERDiagramStagedOverlay.TableEdits(columns: [], foreignKeys: [])

        let staged = ERDiagramStagedOverlay.apply([Self.composed: edits], to: Self.twinGraph())

        #expect(staged.nodes.first { $0.id == staged.nodeIndex[Self.composed] }?.columns.isEmpty == true)
        #expect(staged.nodes.first { $0.id == staged.nodeIndex[Self.decomposed] }?.columns.map(\.name) == ["id", "b"])
    }

    @Test("A Mermaid export names the twins as two entities")
    func mermaidNamesTwinsApart() {
        let names = ERDiagramMermaidWriter.entityNames(for: [TwinNames.composed, TwinNames.decomposed])

        #expect(names.count == 2)
        #expect(names[Self.composed] != names[Self.decomposed])
    }
}
