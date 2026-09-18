import Foundation
@testable import TablePro
import Testing

@Suite("Schema-qualified names")
struct SchemaQualifiedNameTests {
    private static func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func render(_ name: String, schema: String?, implicit: String? = nil) -> String {
        SchemaQualifiedName.render(name: name, schema: schema, implicitSchemaName: implicit, quote: Self.quote)
    }

    @Test("No schema writes the bare quoted name")
    func nilSchema() {
        #expect(render("orders", schema: nil) == "\"orders\"")
    }

    @Test("An empty schema is no schema")
    func emptySchema() {
        #expect(render("orders", schema: "") == "\"orders\"")
        #expect(render("orders", schema: "", implicit: "(default)") == "\"orders\"")
    }

    @Test("The engine's implicit schema is written unqualified")
    func implicitSchema() {
        #expect(render("orders", schema: "(default)", implicit: "(default)") == "\"orders\"")
    }

    @Test("A named schema qualifies the name, even when the engine has an implicit one")
    func namedSchema() {
        #expect(render("orders", schema: "sales") == "\"sales\".\"orders\"")
        #expect(render("orders", schema: "sales", implicit: "(default)") == "\"sales\".\"orders\"")
    }

    @Test("An engine with no implicit schema quotes a schema that merely looks like one")
    func implicitNameIsPerEngine() {
        #expect(render("orders", schema: "(default)") == "\"(default)\".\"orders\"")
    }

    @Test("Both parts go through the engine's quoting")
    func quotingAppliesToBothParts() {
        #expect(render("or\"ders", schema: "sa\"les") == "\"sa\"\"les\".\"or\"\"ders\"")
    }

    @Test("The implicit schema comes from the engine's curated metadata")
    func implicitSchemaFromDatabaseType() {
        #expect(
            SchemaQualifiedName.render(name: "orders", schema: "(default)", databaseType: .spanner, quote: Self.quote)
                == "\"orders\""
        )
        #expect(
            SchemaQualifiedName.render(
                name: "orders", schema: "(default)", databaseType: .postgresql, quote: Self.quote
            ) == "\"(default)\".\"orders\""
        )
        #expect(SchemaQualifiedName.explicitSchema("(default)", databaseType: .spanner) == nil)
        #expect(SchemaQualifiedName.explicitSchema("sales", databaseType: .spanner) == "sales")
        #expect(DatabaseType.postgresql.implicitSchemaName == nil)
    }
}
