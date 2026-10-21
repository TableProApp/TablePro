import Foundation
@testable import TablePro
import Testing

struct ERDiagramDOTWriterTests {
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
                "users": [column("id", primaryKey: true), column("email", type: "text")],
                "orders": [column("id", primaryKey: true), column("user_id", nullable: true)],
            ],
            allForeignKeys: ["orders": [foreignKey("orders_user_id_fkey", column: "user_id", references: "users")]]
        )
    }

    @Test("Each table is an HTML-like label with one row per column")
    func tableLabels() {
        let document = ERDiagramDOTWriter.document(for: shop)

        #expect(document.hasPrefix("digraph \"ER Diagram\" {\n"))
        #expect(document.contains("""
            "orders" [label=<
                <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="4">
                    <TR><TD ALIGN="LEFT" BGCOLOR="#EFEFF4"><B>orders</B></TD></TR>
                    <TR><TD ALIGN="LEFT" PORT="id">id <FONT COLOR="#6E6E73">integer</FONT> <FONT COLOR="#6E6E73" POINT-SIZE="9">PK</FONT></TD></TR>
                    <TR><TD ALIGN="LEFT" PORT="user_id">user_id <FONT COLOR="#6E6E73">integer</FONT> <FONT COLOR="#6E6E73" POINT-SIZE="9">FK</FONT></TD></TR>
                </TABLE>
            >];
        """))
        #expect(document.hasSuffix("}\n"))
    }

    @Test("A foreign key is an edge between the two column ports")
    func edgeBetweenPorts() {
        #expect(ERDiagramDOTWriter.document(for: shop).contains(
            "    \"orders\":\"user_id\" -> \"users\":\"id\" [arrowtail=crowodot, arrowhead=tee];\n"
        ))
    }

    @Test("Each cardinality draws Graphviz's crow, tee and odot as the canvas draws its markers", arguments: [
        (ERCardinality.oneToOne, "teetee", "tee"),
        (.zeroOrOneToOne, "teeodot", "tee"),
        (.manyToOne, "crowtee", "tee"),
        (.zeroOrManyToOne, "crowodot", "tee"),
        (.manyToMany, "crow", "crow"),
    ])
    func arrows(cardinality: ERCardinality, tail: String, head: String) {
        let arrows = ERDiagramDOTWriter.arrows(cardinality)

        #expect(arrows.tail == tail)
        #expect(arrows.head == head)
    }

    @Test("An edge to a column the view hides meets the table instead of a missing port")
    func hiddenColumnHasNoPort() {
        var graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true), column("email", type: "text")],
                "orders": [column("id", primaryKey: true), column("user_email", type: "text")],
            ],
            allForeignKeys: ["orders": [foreignKey("fk", column: "user_email", references: "users", "email")]]
        )
        graph.nodes = graph.nodes.map { node in
            var compact = node
            compact.displayColumns = node.columns.filter { $0.isPrimaryKey || $0.isForeignKey }
            return compact
        }
        let document = ERDiagramDOTWriter.document(for: graph)

        #expect(document.contains("    \"orders\":\"user_email\" -> \"users\" [arrowtail=crowtee, arrowhead=tee];\n"))
        #expect(!document.contains("PORT=\"email\""))
    }

    @Test("A collapsed junction table is one edge with a crow at each end")
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

        #expect(ERDiagramDOTWriter.document(for: graph).contains(
            "    \"users\" -> \"roles\" [arrowtail=crow, arrowhead=crow];\n"
        ))
    }

    @Test("Names are escaped for DOT and for the label's XML")
    func escaping() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: ["a\"b<c>&d": [column("x\"y", type: "t<1>", primaryKey: true), column("back\\slash")]],
            allForeignKeys: [:]
        )
        let document = ERDiagramDOTWriter.document(for: graph)

        #expect(document.contains("    \"a\\\"b<c>&d\" [label=<\n"))
        #expect(document.contains("<B>a&quot;b&lt;c&gt;&amp;d</B>"))
        #expect(document.contains("PORT=\"x_y\">x&quot;y <FONT COLOR=\"#6E6E73\">t&lt;1&gt;</FONT>"))
        #expect(document.contains("<TD ALIGN=\"LEFT\" PORT=\"back_slash\">back\\\\slash"))
    }

    @Test("A backslash is doubled in a label, so \\N and \\G stay text instead of the node and graph names")
    func backslashInLabel() {
        #expect(ERDiagramDOTWriter.html("a\\Nb \\G") == "a\\\\Nb \\\\G")
    }

    @Test("A port is the column name cut to letters, digits and underscores, unique in its table")
    func portIds() {
        #expect(ERDiagramDOTWriter.portIds(for: ["id", "id:s", "id_s", "名前", "user id", ""]) == [
            "id": "id", "id:s": "id_s", "id_s": "id_s_2", "名前": "_", "user id": "user_id", "": "_2",
        ])
    }

    @Test("A colon in a column name never reaches Graphviz as a compass point")
    func colonInColumnName() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "parent": [column("id", primaryKey: true), column("id:s", type: "text")],
                "child": [column("id", primaryKey: true), column("parent_ref", type: "text")],
            ],
            allForeignKeys: ["child": [foreignKey("fk", column: "parent_ref", references: "parent", "id:s")]]
        )
        let document = ERDiagramDOTWriter.document(for: graph)

        #expect(document.contains("<TD ALIGN=\"LEFT\" PORT=\"id_s\">id:s"))
        #expect(document.contains("    \"child\":\"parent_ref\" -> \"parent\":\"id_s\" [arrowtail=crowtee, arrowhead=tee];\n"))
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
        let first = ERDiagramDOTWriter.document(for: graph)
        graph.edges.reverse()
        graph.nodes.reverse()

        #expect(ERDiagramDOTWriter.document(for: graph) == first)
    }
}
