import Testing
@testable import TableProR2SQLCore

@Suite("R2 SQL catalog statements")
struct R2SQLIntrospectionSQLTests {
    private func result(_ columns: [String], _ rows: [[String: R2SQLJSONValue]]) -> R2SQLResult {
        R2SQLResult(schema: columns.map { R2SQLField(name: $0, typeName: "utf8") }, rows: rows)
    }

    @Test("Statements quote the namespace and table as identifiers")
    func statements() {
        #expect(R2SQLIntrospectionSQL.showTables(namespace: "logs") == #"SHOW TABLES IN "logs""#)
        #expect(R2SQLIntrospectionSQL.describe(namespace: "lo\"gs", table: "events")
            == #"DESCRIBE "lo""gs"."events""#)
    }

    @Test("A Spark-shaped SHOW TABLES reads the tableName column, not the namespace")
    func sparkShape() throws {
        let listing = result(["namespace", "tableName", "isTemporary"], [
            ["namespace": .string("logs"), "tableName": .string("zeta"), "isTemporary": .bool(false)],
            ["namespace": .string("logs"), "tableName": .string("alpha"), "isTemporary": .bool(false)]
        ])
        #expect(try R2SQLIntrospectionSQL.tables(from: listing) == ["alpha", "zeta"])
    }

    @Test("A DataFusion-shaped SHOW TABLES reads table_name, not the catalog")
    func dataFusionShape() throws {
        let listing = result(["table_catalog", "table_schema", "table_name", "table_type"], [
            ["table_catalog": .string("r2"), "table_schema": .string("logs"),
             "table_name": .string("events"), "table_type": .string("BASE TABLE")]
        ])
        #expect(try R2SQLIntrospectionSQL.tables(from: listing) == ["events"])
    }

    @Test("A single-column listing reads that column")
    func singleColumn() throws {
        let listing = result(["db"], [["db": .string("logs")], ["db": .string("default")]])
        #expect(try R2SQLIntrospectionSQL.namespaces(from: listing) == ["default", "logs"])
    }

    @Test("A listing with no recognizable name column is reported, not guessed")
    func unknownShapeThrows() {
        let listing = result(["a", "b"], [["a": .string("x"), "b": .string("y")]])
        #expect(throws: R2SQLError.unexpectedResult(
            "SHOW TABLES returned columns TablePro does not recognize: a, b."
        )) {
            try R2SQLIntrospectionSQL.tables(from: listing)
        }
    }

    @Test("DESCRIBE reads columns by name: nullable is the inverse of required, and doc is the comment")
    func describeByName() throws {
        let description = result(["column_name", "type", "required", "initial_default", "write_default", "doc"], [
            ["column_name": .string("sale_id"), "type": .string("BIGINT"), "required": .bool(false),
             "doc": .string("Unique identifier")],
            ["column_name": .string("region"), "type": .string("TEXT"), "required": .string("true"),
             "doc": .string("")]
        ])
        #expect(try R2SQLIntrospectionSQL.columns(from: description) == [
            R2SQLColumnDescription(name: "sale_id", typeName: "BIGINT", isNullable: true, comment: "Unique identifier"),
            R2SQLColumnDescription(name: "region", typeName: "TEXT", isNullable: false, comment: nil)
        ])
    }

    @Test("A DESCRIBE result without column_name and type is reported")
    func describeWithoutColumnsThrows() {
        #expect(throws: R2SQLError.self) {
            try R2SQLIntrospectionSQL.columns(from: result(["name", "kind"], []))
        }
    }
}
