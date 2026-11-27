import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct JoinGraphTwinTests {
    private static let composed = CatalogName(TwinNames.composed)
    private static let decomposed = CatalogName(TwinNames.decomposed)

    private static func graph() -> JoinGraph {
        JoinGraph(
            columns: [composed: ["id", "a"], decomposed: ["id", "b"], "child": ["id", "parent_id"]],
            foreignKeys: ["child": [ForeignKeyInfo(
                name: "child_parent", column: "parent_id", referencedTable: TwinNames.decomposed, referencedColumn: "id"
            )]],
            isLocal: { _ in true }
        )
    }

    @Test("Two tables whose names differ only in Unicode form are two tables with their own columns")
    func twinsAreTwoTables() {
        let graph = Self.graph()

        #expect(graph.tableNames.count == 3)
        #expect(graph.columns(of: Self.composed) == ["id", "a"])
        #expect(graph.columns(of: Self.decomposed) == ["id", "b"])
    }

    @Test("A key to one twin joins that twin, and the draft holds both twins apart")
    func keyJoinsTheNamedTwin() {
        let graph = Self.graph()
        var draft = JoinQueryDraft()

        draft.add("child", in: graph)
        draft.add(Self.decomposed, in: graph)
        draft.add(Self.composed, in: graph)

        #expect(graph.relationships(between: "child", and: Self.decomposed).count == 1)
        #expect(graph.relationships(between: "child", and: Self.composed).isEmpty)
        #expect(draft.tables.map(\.name) == ["child", Self.decomposed, Self.composed])
        #expect(draft.tables[1].condition?.parentTable == Self.decomposed)
        #expect(draft.tables[2].condition == nil)
    }
}
