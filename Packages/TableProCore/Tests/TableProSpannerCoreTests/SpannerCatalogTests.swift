import Foundation
import TableProSpannerCore
import Testing

private func catalogRow(_ values: String?...) -> [SpannerCell] {
    values.map { $0.map(SpannerCell.text) ?? .null }
}

@Suite("SpannerCatalogSQL")
struct SpannerCatalogSQLTests {
    private let string = SpannerType(code: "STRING")

    @Test("Schemas need no parameters")
    func schemas() {
        let statement = SpannerCatalogSQL.schemas(dialect: .googleSQL)
        #expect(statement.sql == "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name")
        #expect(statement.parameters.isEmpty)
        #expect(statement.parameterTypes?.isEmpty == true)
    }

    @Test("Tables bind the schema as a STRING")
    func tables() {
        let google = SpannerCatalogSQL.tables(schema: "", dialect: .googleSQL)
        #expect(google.sql == "SELECT table_schema, table_name, table_type FROM information_schema.tables"
            + " WHERE table_schema = @p1 AND table_type IN ('BASE TABLE', 'VIEW') ORDER BY table_name")
        #expect(google.parameters == [.text("")])
        #expect(google.parameterTypes == [string])
        let postgres = SpannerCatalogSQL.tables(schema: "public", dialect: .postgreSQL)
        #expect(postgres.sql.contains("WHERE table_schema = $1 AND"))
        #expect(postgres.parameters == [.text("public")])
    }

    @Test("Columns select the hidden flag only where it exists and find the key through PRIMARY_KEY")
    func columns() {
        let bulk = SpannerCatalogSQL.columns(schema: "", table: nil, dialect: .googleSQL)
        #expect(bulk.sql == "SELECT c.table_schema, c.table_name, c.column_name, c.spanner_type, c.is_nullable, c.column_default,"
            + " c.is_generated, c.generation_expression, c.is_stored, c.is_identity, c.identity_generation,"
            + " c.is_hidden, k.ordinal_position"
            + " FROM information_schema.columns AS c"
            + " LEFT JOIN information_schema.index_columns AS k"
            + " ON k.table_schema = c.table_schema AND k.table_name = c.table_name"
            + " AND k.column_name = c.column_name AND k.index_type = 'PRIMARY_KEY'"
            + " WHERE c.table_schema = @p1"
            + " ORDER BY c.table_name, c.ordinal_position")
        #expect(bulk.parameters == [.text("")])
        let one = SpannerCatalogSQL.columns(schema: "public", table: "child", dialect: .postgreSQL)
        #expect(one.sql.contains(" c.identity_generation, 'NO', k.ordinal_position"))
        #expect(one.sql.contains("WHERE c.table_schema = $1 AND c.table_name = $2 ORDER BY"))
        #expect(one.parameters == [.text("public"), .text("child")])
        #expect(one.parameterTypes == [string, string])
    }

    @Test("Indexes drop STORING columns in SQL")
    func indexes() {
        let statement = SpannerCatalogSQL.indexes(schema: "sales", table: "Orders", dialect: .googleSQL)
        #expect(statement.sql == "SELECT i.table_schema, i.table_name, i.index_name, i.index_type, i.is_unique, i.spanner_is_managed,"
            + " ic.column_name, ic.ordinal_position"
            + " FROM information_schema.indexes AS i"
            + " JOIN information_schema.index_columns AS ic"
            + " ON ic.table_schema = i.table_schema AND ic.table_name = i.table_name AND ic.index_name = i.index_name"
            + " WHERE i.table_schema = @p1 AND i.table_name = @p2 AND ic.ordinal_position IS NOT NULL"
            + " ORDER BY i.table_name, i.index_name, ic.ordinal_position")
        #expect(statement.parameters == [.text("sales"), .text("Orders")])
    }

    @Test("Foreign keys pair columns by position in the referenced constraint")
    func foreignKeys() {
        let statement = SpannerCatalogSQL.foreignKeys(schema: "", table: nil, dialect: .googleSQL)
        #expect(statement.sql == "SELECT c.table_schema, c.table_name, c.constraint_name, c.column_name,"
            + " p.table_schema, p.table_name, p.column_name, r.delete_rule"
            + " FROM information_schema.key_column_usage AS c"
            + " JOIN information_schema.referential_constraints AS r"
            + " ON r.constraint_schema = c.constraint_schema AND r.constraint_name = c.constraint_name"
            + " JOIN information_schema.key_column_usage AS p"
            + " ON p.constraint_schema = r.unique_constraint_schema AND p.constraint_name = r.unique_constraint_name"
            + " AND p.ordinal_position = c.position_in_unique_constraint"
            + " WHERE c.table_schema = @p1"
            + " ORDER BY c.table_name, c.constraint_name, c.ordinal_position")
    }

    @Test("Interleave parents join the parent's primary key")
    func interleave() {
        let statement = SpannerCatalogSQL.interleaveParents(schema: "public", table: "albums", dialect: .postgreSQL)
        #expect(statement.sql == "SELECT t.table_schema, t.table_name, t.parent_table_name, t.on_delete_action, t.interleave_type, k.column_name"
            + " FROM information_schema.tables AS t"
            + " JOIN information_schema.index_columns AS k"
            + " ON k.table_schema = t.table_schema AND k.table_name = t.parent_table_name"
            + " AND k.index_type = 'PRIMARY_KEY'"
            + " WHERE t.table_schema = $1 AND t.table_name = $2 AND t.parent_table_name IS NOT NULL"
            + " ORDER BY t.table_name, k.ordinal_position")
        #expect(statement.parameterTypes == [string, string])
    }

    @Test("A view definition binds schema and name")
    func viewDefinition() {
        let statement = SpannerCatalogSQL.viewDefinition(schema: "", name: "x' OR TRUE --", dialect: .googleSQL)
        #expect(statement.sql == "SELECT view_definition FROM information_schema.views WHERE table_schema = @p1 AND table_name = @p2")
        #expect(statement.parameters == [.text(""), .text("x' OR TRUE --")])
    }
}

@Suite("SpannerCatalogParser")
struct SpannerCatalogParserTests {
    @Test("Schemas keep the nameless default and drop system schemas")
    func schemas() {
        let google = [catalogRow(""), catalogRow("INFORMATION_SCHEMA"), catalogRow("SPANNER_SYS"), catalogRow("sales")]
        #expect(SpannerCatalogParser.schemas(google, dialect: .googleSQL) == ["", "sales"])
        let postgres = [catalogRow("information_schema"), catalogRow("pg_catalog"), catalogRow("public"), catalogRow("sales"), catalogRow("spanner_sys")]
        #expect(SpannerCatalogParser.schemas(postgres, dialect: .postgreSQL) == ["public", "sales"])
    }

    @Test("Tables and views")
    func tables() {
        let rows = [catalogRow("", "Albums", "BASE TABLE"), catalogRow("", "SingerNames", "VIEW"), catalogRow(nil, "Broken", "VIEW")]
        #expect(SpannerCatalogParser.tables(rows) == [
            SpannerTableInfo(schema: "", name: "Albums", isView: false),
            SpannerTableInfo(schema: "", name: "SingerNames", isView: true)
        ])
    }

    @Test("GoogleSQL columns: key, default, stored generation, hidden and identity")
    func googleSQLColumns() {
        let rows = [
            catalogRow("", "T2", "Id", "INT64", "NO", nil, "NEVER", nil, nil, "NO", nil, "false", "1"),
            catalogRow("", "T2", "D", "STRING(MAX)", "YES", "'dflt'", "NEVER", nil, nil, "NO", nil, "false", nil),
            catalogRow("", "T2", "G", "STRING(MAX)", "YES", nil, "ALWAYS", "CONCAT(D, '!')", "YES", "NO", nil, "false", nil),
            catalogRow("", "T2", "H", "STRING(MAX)", "YES", nil, "NEVER", nil, nil, "NO", nil, "true", nil),
            catalogRow("", "T3", "Id", "INT64", "NO", nil, "NEVER", nil, nil, "YES", "BY DEFAULT", "false", "1"),
            catalogRow("", "Docs", "K", "BYTES(16)", "NO", nil, "NEVER", nil, nil, "NO", nil, "false", "2")
        ]
        #expect(SpannerCatalogParser.columns(rows) == [
            SpannerColumnInfo(schema: "", table: "T2", name: "Id", spannerType: "INT64", isNullable: false, isPrimaryKey: true),
            SpannerColumnInfo(schema: "", table: "T2", name: "D", spannerType: "STRING(MAX)", isNullable: true, isPrimaryKey: false,
                              defaultExpression: "'dflt'"),
            SpannerColumnInfo(schema: "", table: "T2", name: "G", spannerType: "STRING(MAX)", isNullable: true, isPrimaryKey: false,
                              isGenerated: true, generationExpression: "CONCAT(D, '!')", isStored: true),
            SpannerColumnInfo(schema: "", table: "T2", name: "H", spannerType: "STRING(MAX)", isNullable: true, isPrimaryKey: false,
                              isHidden: true),
            SpannerColumnInfo(schema: "", table: "T3", name: "Id", spannerType: "INT64", isNullable: false, isPrimaryKey: true,
                              identityGeneration: "BY DEFAULT"),
            SpannerColumnInfo(schema: "", table: "Docs", name: "K", spannerType: "BYTES(16)", isNullable: false, isPrimaryKey: true)
        ])
    }

    @Test("PostgreSQL columns report YES and NO strings")
    func postgreSQLColumns() {
        let rows = [
            catalogRow("public", "t2", "g", "character varying", "YES", nil, "ALWAYS", "(d || '!'::text)", "YES", "NO", nil, "NO", nil),
            catalogRow("public", "t3", "id", "bigint", "NO", nil, "NEVER", nil, nil, "YES", "BY DEFAULT", "NO", "1"),
            catalogRow("public", "t2", "d", "character varying", "YES", "'dflt'::text", "NEVER", nil, nil, nil, nil, "NO", nil)
        ]
        let columns = SpannerCatalogParser.columns(rows)
        #expect(columns.count == 3)
        #expect(columns[0].isGenerated && columns[0].isStored && columns[0].generationExpression == "(d || '!'::text)")
        #expect(columns[1].isPrimaryKey && columns[1].identityGeneration == "BY DEFAULT" && !columns[1].isNullable)
        #expect(columns[2].defaultExpression == "'dflt'::text" && columns[2].identityGeneration == nil && !columns[2].isHidden)
    }

    @Test("Indexes group key columns in order, flag the primary key and managed indexes, and skip STORING")
    func indexes() {
        let rows = [
            catalogRow("", "Child", "IDX_Child_X_Y_N_6C2AD26B4F077B71", "INDEX", "false", "true", "Y", "2"),
            catalogRow("", "Child", "IDX_Child_X_Y_N_6C2AD26B4F077B71", "INDEX", "false", "true", "X", "1"),
            catalogRow("", "Child", "PRIMARY_KEY", "PRIMARY_KEY", "true", "false", "Id", "1"),
            catalogRow("", "Singers", "SingersByAgeName", "INDEX", "true", "false", "Age", "1"),
            catalogRow("", "Singers", "SingersByAgeName", "INDEX", "true", "false", "Name", "2"),
            catalogRow("", "Singers", "SingersByName", "INDEX", "false", "false", "Age", nil),
            catalogRow("", "Singers", "SingersByName", "INDEX", "false", "false", "Name", "1")
        ]
        #expect(SpannerCatalogParser.indexes(rows) == [
            SpannerIndexInfo(schema: "", table: "Child", name: "IDX_Child_X_Y_N_6C2AD26B4F077B71", columns: ["X", "Y"],
                             isUnique: false, isPrimaryKey: false, isManaged: true, type: "INDEX"),
            SpannerIndexInfo(schema: "", table: "Child", name: "PRIMARY_KEY", columns: ["Id"],
                             isUnique: true, isPrimaryKey: true, isManaged: false, type: "PRIMARY_KEY"),
            SpannerIndexInfo(schema: "", table: "Singers", name: "SingersByAgeName", columns: ["Age", "Name"],
                             isUnique: true, isPrimaryKey: false, isManaged: false, type: "INDEX"),
            SpannerIndexInfo(schema: "", table: "Singers", name: "SingersByName", columns: ["Name"],
                             isUnique: false, isPrimaryKey: false, isManaged: false, type: "INDEX")
        ])
    }

    @Test("PostgreSQL index flags arrive as YES and NO")
    func postgresIndexes() {
        let rows = [
            catalogRow("public", "child", "IDX_child_x_y_N_6E2D1530E12DA9EC", "INDEX", "NO", "YES", "x", "1"),
            catalogRow("public", "singers", "singers_by_name", "INDEX", "NO", "NO", "age", nil),
            catalogRow("public", "singers", "PRIMARY_KEY", "PRIMARY_KEY", "YES", "NO", "id", "1")
        ]
        let indexes = SpannerCatalogParser.indexes(rows)
        #expect(indexes.map(\.name) == ["IDX_child_x_y_N_6E2D1530E12DA9EC", "PRIMARY_KEY"])
        #expect(indexes[0].isManaged && !indexes[0].isUnique)
        #expect(indexes[1].isPrimaryKey && indexes[1].isUnique)
    }

    @Test("A composite foreign key keeps its column pairs and an interleave parent becomes a relation")
    func foreignKeys() {
        let rows = [
            catalogRow("", "Child", "FK_XY", "X", "", "Parent", "A", "CASCADE"),
            catalogRow("", "Child", "FK_XY", "Y", "", "Parent", "B", "CASCADE"),
            catalogRow("sales", "Orders", "FK_OrderSinger", "SingerId", "", "Singers", "Id", "NO ACTION")
        ]
        let interleave = [
            catalogRow("", "Albums", "Singers", "CASCADE", "IN PARENT", "Id"),
            catalogRow("", "Songs", "Albums", "NO ACTION", "IN PARENT", "Id"),
            catalogRow("", "Songs", "Albums", "NO ACTION", "IN PARENT", "AlbumId"),
            catalogRow("", "Loose", "Albums", nil, "IN", "Id")
        ]
        #expect(SpannerCatalogParser.foreignKeys(rows, interleaveRows: interleave) == [
            SpannerForeignKeyInfo(schema: "", table: "Child", name: "FK_XY", columns: ["X", "Y"], referencedSchema: "",
                                  referencedTable: "Parent", referencedColumns: ["A", "B"], onDelete: "CASCADE", isInterleave: false),
            SpannerForeignKeyInfo(schema: "sales", table: "Orders", name: "FK_OrderSinger", columns: ["SingerId"], referencedSchema: "",
                                  referencedTable: "Singers", referencedColumns: ["Id"], onDelete: "NO ACTION", isInterleave: false),
            SpannerForeignKeyInfo(schema: "", table: "Albums", name: "INTERLEAVE IN PARENT Singers", columns: ["Id"], referencedSchema: "",
                                  referencedTable: "Singers", referencedColumns: ["Id"], onDelete: "CASCADE", isInterleave: true),
            SpannerForeignKeyInfo(schema: "", table: "Songs", name: "INTERLEAVE IN PARENT Albums", columns: ["Id", "AlbumId"],
                                  referencedSchema: "", referencedTable: "Albums", referencedColumns: ["Id", "AlbumId"],
                                  onDelete: "NO ACTION", isInterleave: true),
            SpannerForeignKeyInfo(schema: "", table: "Loose", name: "INTERLEAVE IN Albums", columns: ["Id"], referencedSchema: "",
                                  referencedTable: "Albums", referencedColumns: ["Id"], onDelete: nil, isInterleave: true)
        ])
    }

    @Test("PostgreSQL foreign keys across schemas")
    func postgresForeignKeys() {
        let rows = [catalogRow("sales", "orders", "fk_order_singer", "singer_id", "public", "singers", "id", "NO ACTION")]
        let interleave = [catalogRow("sales", "items", "orders", "CASCADE", "IN PARENT", "id")]
        let keys = SpannerCatalogParser.foreignKeys(rows, interleaveRows: interleave)
        #expect(keys.count == 2)
        #expect(keys[0].referencedSchema == "public" && keys[0].referencedTable == "singers")
        #expect(keys[1].referencedSchema == "sales" && keys[1].name == "INTERLEAVE IN PARENT orders")
    }

    @Test("Emulator responses decode and parse end to end")
    func emulatorResponses() throws {
        let indexesJSON = #"""
        {"metadata": {"rowType": {"fields": [
            {"name":"table_schema","type":{"code":"STRING"}},
            {"name":"table_name","type":{"code":"STRING"}},
            {"name":"index_name","type":{"code":"STRING"}},
            {"name":"index_type","type":{"code":"STRING"}},
            {"name":"is_unique","type":{"code":"BOOL"}},
            {"name":"spanner_is_managed","type":{"code":"BOOL"}},
            {"name":"column_name","type":{"code":"STRING"}},
            {"name":"ordinal_position","type":{"code":"INT64"}}
        ]}}, "rows": [
            ["","Singers","PRIMARY_KEY","PRIMARY_KEY",true,false,"Id","1"],
            ["","Singers","SingersByAgeName","INDEX",true,false,"Age","1"],
            ["","Singers","SingersByAgeName","INDEX",true,false,"Name","2"],
            ["","Singers","SingersByName","INDEX",false,false,"Name","1"]
        ]}
        """#
        let columnsJSON = #"""
        {"metadata": {"rowType": {"fields": [
            {"name":"table_schema","type":{"code":"STRING"}},
            {"name":"table_name","type":{"code":"STRING"}},
            {"name":"column_name","type":{"code":"STRING"}},
            {"name":"spanner_type","type":{"code":"STRING"}},
            {"name":"is_nullable","type":{"code":"STRING"}},
            {"name":"column_default","type":{"code":"STRING"}},
            {"name":"is_generated","type":{"code":"STRING"}},
            {"name":"generation_expression","type":{"code":"STRING"}},
            {"name":"is_stored","type":{"code":"STRING"}},
            {"name":"is_identity","type":{"code":"STRING"}},
            {"name":"identity_generation","type":{"code":"STRING"}},
            {"name":"?column?","type":{"code":"STRING"}},
            {"name":"ordinal_position","type":{"code":"INT64"}}
        ]}}, "rows": [
            ["public","t2","id","bigint","NO",null,"NEVER",null,null,"NO",null,"NO","1"],
            ["public","t2","d","character varying","YES","'dflt'::text","NEVER",null,null,"NO",null,"NO",null],
            ["public","t2","g","character varying","YES",null,"ALWAYS","(d || '!'::text)","YES","NO",null,"NO",null],
            ["public","t3","id","bigint","NO",null,"NEVER",null,null,"YES","BY DEFAULT","NO","1"],
            ["public","t3","v","character varying","YES",null,"NEVER",null,null,"NO",null,"NO",null]
        ]}
        """#
        let indexes = try decodedRows(indexesJSON)
        #expect(SpannerCatalogParser.indexes(indexes).map(\.columns) == [["Id"], ["Age", "Name"], ["Name"]])
        #expect(SpannerCatalogParser.indexes(indexes).map(\.isUnique) == [true, true, false])
        let columns = SpannerCatalogParser.columns(try decodedRows(columnsJSON))
        #expect(columns.map(\.name) == ["id", "d", "g", "id", "v"])
        #expect(columns.map(\.isPrimaryKey) == [true, false, false, true, false])
        #expect(columns[1].defaultExpression == "'dflt'::text")
        #expect(columns[2].isGenerated && columns[2].isStored)
        #expect(columns[3].identityGeneration == "BY DEFAULT")
    }

    private func decodedRows(_ json: String) throws -> [[SpannerCell]] {
        let resultSet = try JSONDecoder().decode(SpannerResultSet.self, from: Data(json.utf8))
        return SpannerValueDecoder.rows(resultSet.rows, fields: resultSet.metadata?.fields ?? [])
    }

    @Test("View definition")
    func viewDefinition() {
        #expect(SpannerCatalogParser.viewDefinition([catalogRow("SELECT Singers.Id, Singers.Name FROM Singers")])
            == "SELECT Singers.Id, Singers.Name FROM Singers")
        #expect(SpannerCatalogParser.viewDefinition([]) == nil)
        #expect(SpannerCatalogParser.viewDefinition([catalogRow(nil)]) == nil)
    }
}
