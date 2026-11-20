import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct CascadeTwinTableTests {
    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")

    private static func root(_ table: String) -> CascadeDeleteRoot {
        CascadeDeleteRoot(table: table, columns: ["id"], primaryKeyColumns: ["id"], rows: [[.text("1")]])
    }

    private static func environment(schema: String = "public") -> CascadeDeletePreviewer.Environment {
        CascadeDeletePreviewer.Environment(
            slot: .schema,
            tableNames: CascadeTableNames(databaseType: .postgresql),
            dialect: CascadeDeleteSQLTests.dialect,
            readForeignKeys: {
                ["child": [ForeignKeyInfo(
                    name: "child_parent", column: "parent_id", referencedTable: TwinNames.decomposed,
                    referencedColumn: "id", referencedSchema: schema, onDelete: "CASCADE"
                )]]
            },
            count: { _ in 1 }
        )
    }

    @Test("A key to one of two tables whose names differ only in Unicode form cascades from that table only")
    func keyCascadesFromItsOwnTwin() async {
        let fromComposed = await CascadeDeletePreviewer.preview(
            of: Self.root(TwinNames.composed), in: scope, environment: Self.environment()
        )
        let fromDecomposed = await CascadeDeletePreviewer.preview(
            of: Self.root(TwinNames.decomposed), in: scope, environment: Self.environment()
        )

        #expect(fromComposed == nil)
        guard case .checked(let lines, _)? = fromDecomposed?.outcome else {
            Issue.record("Expected a checked preview, got \(String(describing: fromDecomposed))")
            return
        }
        #expect(lines.map(\.table) == ["child"])
    }

    @Test("A key into a twin schema does not cascade into this one")
    func keyIntoTwinSchemaIsOutside() async {
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: TwinNames.composed)

        let preview = await CascadeDeletePreviewer.preview(
            of: Self.root(TwinNames.decomposed), in: scope, environment: Self.environment(schema: TwinNames.decomposed)
        )

        #expect(preview == nil)
    }

    @Test("SQLite folds ASCII letters only, so two tables that differ by a non-ASCII case stay two")
    func sqliteFoldsASCIIOnly() {
        let names = CascadeTableNames(databaseType: .sqlite)

        #expect(names.key("Orders") == names.key("orders"))
        #expect(names.key("CAF\u{C9}") != names.key("caf\u{E9}"))
        #expect(names.key(TwinNames.composed) != names.key(TwinNames.decomposed))
    }
}
