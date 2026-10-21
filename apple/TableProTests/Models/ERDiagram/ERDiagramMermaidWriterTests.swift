import Foundation
@testable import TablePro
import Testing

struct ERDiagramMermaidWriterTests {
    private func column(
        _ name: String,
        type: String = "integer",
        nullable: Bool = false,
        primaryKey: Bool = false
    ) -> ColumnInfo {
        ColumnInfo(name: name, dataType: type, isNullable: nullable, isPrimaryKey: primaryKey)
    }

    private func foreignKey(_ name: String, column: String, references table: String, _ refColumn: String = "id") -> ForeignKeyInfo {
        ForeignKeyInfo(name: name, column: column, referencedTable: table, referencedColumn: refColumn)
    }

    private var shop: ERDiagramGraph {
        ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true), column("email", type: "character varying(255)")],
                "orders": [
                    column("id", primaryKey: true),
                    column("user_id"),
                    column("total", type: "numeric(10,2)", nullable: true),
                ],
            ],
            allForeignKeys: ["orders": [foreignKey("orders_user_id_fkey", column: "user_id", references: "users")]]
        )
    }

    @Test("Each table lists its columns with types and keys, then each foreign key as a relationship")
    func writesTablesAndRelationships() {
        #expect(ERDiagramMermaidWriter.document(for: shop) == """
        erDiagram
            "orders" {
                integer id PK
                integer user_id FK
                numeric(10_2) total
            }
            "users" {
                integer id PK
                character_varying(255) email
            }
            "orders" }|--|| "users" : "user_id"

        """)
    }

    @Test("Each cardinality carries the markers the canvas draws at each end", arguments: [
        (ERCardinality.oneToOne, "||--||"),
        (.zeroOrOneToOne, "|o--||"),
        (.manyToOne, "}|--||"),
        (.zeroOrManyToOne, "}o--||"),
        (.manyToMany, "}o--o{"),
    ])
    func cardinalityMarkers(cardinality: ERCardinality, expected: String) {
        #expect(ERDiagramMermaidWriter.relationship(cardinality) == expected)
    }

    @Test("A column that is both keys is marked PK, FK")
    func primaryAndForeignKey() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "user_settings": [column("user_id", primaryKey: true)],
            ],
            allForeignKeys: ["user_settings": [foreignKey("fk", column: "user_id", references: "users")]]
        )
        let document = ERDiagramMermaidWriter.document(for: graph)

        #expect(document.contains("        integer user_id PK, FK\n"))
        #expect(document.contains("    \"user_settings\" ||--|| \"users\" : \"user_id\"\n"))
    }

    @Test("A word the Mermaid lexer cannot read is fitted to one it can", arguments: [
        ("character varying(255)", "character_varying(255)"),
        ("timestamp with time zone", "timestamp_with_time_zone"),
        ("numeric(10,2)", "numeric(10_2)"),
        ("text[]", "text[]"),
        ("enum('a','b')", "enum(_a_b_)"),
        ("2fa_secret", "_2fa_secret"),
        ("pk", "_pk"),
        ("FK", "_FK"),
        ("uk-1", "_uk-1"),
        ("pkey", "pkey"),
        ("fk_user", "fk_user"),
        ("user id", "user_id"),
        ("名前", "名前"),
        ("", "_"),
    ])
    func attributeWords(input: String, expected: String) {
        #expect(ERDiagramMermaidWriter.attributeWord(input) == expected)
    }

    @Test("Table names are quoted, so keywords and spaces stay names")
    func entityNames() {
        #expect(ERDiagramMermaidWriter.entityName("end") == "\"end\"")
        #expect(ERDiagramMermaidWriter.entityName("order items") == "\"order items\"")
        #expect(ERDiagramMermaidWriter.entityName("a\"b%c\\d") == "\"a_b_c_d\"")
    }

    @Test("Two tables that fit to the same name stay two entities")
    func fittedNamesStayUnique() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "a%b": [column("id", primaryKey: true), column("ref_id")],
                "a_b": [column("id", primaryKey: true)],
            ],
            allForeignKeys: ["a%b": [foreignKey("fk", column: "ref_id", references: "a_b")]]
        )
        let document = ERDiagramMermaidWriter.document(for: graph)

        #expect(ERDiagramMermaidWriter.entityNames(for: ["a_b", "a%b", "a_b_2"])
            == ["a%b": "\"a_b\"", "a_b": "\"a_b_2\"", "a_b_2": "\"a_b_2_2\""])
        #expect(document.contains("    \"a_b\" {\n"))
        #expect(document.contains("    \"a_b_2\" {\n"))
        #expect(document.contains("    \"a_b\" }|--|| \"a_b_2\" : \"ref_id\"\n"))
    }

    @Test("A name holding a direction directive is not read as one", arguments: [
        ("sort direction LR", "\"sort direction_LR\""),
        ("Direction\ttb", "\"Direction_tb\""),
        ("direction", "\"direction\""),
    ])
    func directionInNames(input: String, expected: String) {
        #expect(ERDiagramMermaidWriter.entityName(input) == expected)
    }

    @Test("The same schema writes the same file whatever order its edges arrive in")
    func stableOrder() {
        var graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "a": [column("id", primaryKey: true), column("b_id"), column("c_id")],
                "b": [column("id", primaryKey: true)],
                "c": [column("id", primaryKey: true), column("b_id")],
            ],
            allForeignKeys: [
                "a": [foreignKey("a_b", column: "b_id", references: "b"), foreignKey("a_c", column: "c_id", references: "c")],
                "c": [foreignKey("c_b", column: "b_id", references: "b")],
            ]
        )
        let first = ERDiagramMermaidWriter.document(for: graph)
        graph.edges.reverse()
        graph.nodes.reverse()

        #expect(ERDiagramMermaidWriter.document(for: graph) == first)
    }

    @Test("Compact mode writes only the columns the canvas shows")
    func writesDisplayedColumns() {
        var graph = shop
        graph.nodes = graph.nodes.map { node in
            var compact = node
            compact.displayColumns = node.columns.filter { $0.isPrimaryKey || $0.isForeignKey }
            return compact
        }
        let document = ERDiagramMermaidWriter.document(for: graph)

        #expect(!document.contains("email"))
        #expect(!document.contains("total"))
        #expect(document.contains("integer user_id FK"))
    }

    @Test("A collapsed junction table is one many-to-many relationship named after it")
    func collapsedJunction() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "roles": [column("id", primaryKey: true)],
                "user_roles": [column("user_id", primaryKey: true), column("role_id", primaryKey: true)],
            ],
            allForeignKeys: ["user_roles": [
                foreignKey("ur_user", column: "user_id", references: "users"),
                foreignKey("ur_role", column: "role_id", references: "roles"),
            ]]
        ).projected(collapseJunctions: true)
        let document = ERDiagramMermaidWriter.document(for: graph)

        #expect(document.contains("    \"users\" }o--o{ \"roles\" : \"user_roles\"\n"))
        #expect(!document.contains("\"user_roles\" {"))
    }

    @Test("A table without columns is declared by name alone")
    func tableWithoutColumns() {
        let graph = ERDiagramGraphBuilder.build(allColumns: ["empty": []], allForeignKeys: [:])

        #expect(ERDiagramMermaidWriter.document(for: graph) == "erDiagram\n    \"empty\"\n")
    }

    @Test("Copy as Mermaid fences the diagram for Markdown")
    func markdownBlock() {
        let block = ERDiagramMermaidWriter.markdownBlock(for: shop)

        #expect(block.hasPrefix("```mermaid\nerDiagram\n"))
        #expect(block.hasSuffix("\n```\n"))
    }
}
