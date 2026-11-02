import Foundation
import TableProPluginKit

// Reads every catalog surface of one schema through the real driver and prints one canonical line per answer.
// `pinned` switches to the schema the way the metadata pool pins a connection; `explicit` sets a path that names the
// schema before pg_catalog, as a database owner's default can. check-postgresql-catalog-shadowing.sh diffs the lines a
// clean schema gives against those the same schema gives once its owner has planted lookalikes.
@main
enum ShadowingProbe {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 7 else {
            FileHandle.standardError.write(Data("usage: probe host port user database schema pinned|explicit\n".utf8))
            exit(2)
        }
        let schema = arguments[5]
        let driver = PostgreSQLPluginDriver(config: DriverConnectionConfig(
            host: arguments[1],
            port: Int(arguments[2]) ?? 5_432,
            username: arguments[3],
            password: ProcessInfo.processInfo.environment["PGPASSWORD"] ?? "",
            database: arguments[4]
        ))
        do {
            try await driver.connect()
            if arguments[6] == "explicit" {
                _ = try await driver.execute(query: "SET search_path = \"\(schema)\", pg_catalog")
            } else {
                try await driver.switchSchema(to: schema)
            }
        } catch {
            print("error|connect|\(error)")
            exit(2)
        }
        await read(driver, schema: schema, database: arguments[4])
        await readTypeCreatedAfterConnect(driver, schema: schema)
        driver.disconnect()
    }

    // The lookalikes are routines in the same schema, so the listings keep to what the fixture created.
    static let fixtureRoutines: Set<String> = ["touch", "label"]

    // A type the connect-time probes never saw sends the type-name lookup, and CREATE TYPE the enum refresh, both on
    // the session's own path.
    static func readTypeCreatedAfterConnect(_ driver: PostgreSQLPluginDriver, schema: String) async {
        let type = "\"\(schema)\".late_pair"
        await attempt("typeCreatedAfterConnect") {
            _ = try await driver.execute(query: "CREATE TYPE \(type) AS (a pg_catalog.int4)")
            let result = try await driver.execute(query: "SELECT ROW(1)::\(type) AS pair")
            line(["late-type", result.columnTypeNames.first, result.rows.first?.first?.asText])
        }
        _ = try? await driver.execute(query: "DROP TYPE IF EXISTS \(type)")
    }

    static func line(_ fields: [String?]) {
        print(fields.map { ($0 ?? "-").replacingOccurrences(of: "\n", with: "\\n") }.joined(separator: "|"))
    }

    static func attempt(_ label: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            line(["error", label, "\(error)"])
        }
    }

    static func column(_ table: String, _ column: PluginColumnInfo) {
        line([
            "column", table, column.name, column.dataType, column.isNullable ? "null" : "not-null",
            column.isPrimaryKey ? "pk" : "-", column.defaultValue, column.collation, column.comment,
            column.isGenerated ? "generated" : "-", column.generationExpression,
            column.allowedValues?.joined(separator: ","), column.ddlSpelling, column.ddlDefault
        ])
    }

    static func read(_ driver: PostgreSQLPluginDriver, schema: String, database: String) async {
        await attempt("fetchTables") {
            for table in try await driver.fetchTables(schema: schema).sorted(by: { $0.name < $1.name }) {
                line(["table", table.name, table.type, table.comment])
            }
        }
        await attempt("fetchTablesInSchemas") {
            let tables = try await driver.fetchTables(inSchemas: [schema]) ?? []
            line(["tables-in-schemas", "\(tables.count)"])
        }
        await attempt("fetchSchemas") {
            line(["schemas", try await driver.fetchSchemas().contains(schema) ? "lists" : "misses"])
        }
        await attempt("fetchDatabases") {
            line(["databases", try await driver.fetchDatabases().contains(database) ? "lists" : "misses"])
        }
        await attempt("fetchDatabaseMetadata") {
            let metadata = try await driver.fetchDatabaseMetadata(database)
            line(["database-metadata", metadata.tableCount.map(String.init), metadata.sizeBytes == nil ? "nil" : "sized"])
        }
        await attempt("fetchColumns") {
            for table in ["orders", "order_view", "order_totals", "places"] {
                for item in try await driver.fetchColumns(table: table, schema: schema) { column(table, item) }
            }
        }
        await attempt("fetchAllColumns") {
            for (table, columns) in try await driver.fetchAllColumns(schema: schema).sorted(by: { $0.key < $1.key }) {
                line(["all-columns", table, columns.map(\.name).joined(separator: ","), columns.map(\.dataType).joined(separator: ",")])
            }
        }
        await attempt("fetchIndexes") {
            for index in try await driver.fetchIndexes(table: "orders", schema: schema) {
                line(["index", index.name, index.columns.joined(separator: ","), index.type, index.whereClause])
            }
        }
        await attempt("fetchAllIndexes") {
            for (table, indexes) in try await driver.fetchAllIndexes(schema: schema).sorted(by: { $0.key < $1.key }) {
                line(["all-indexes", table, indexes.map(\.name).sorted().joined(separator: ",")])
            }
        }
        await attempt("fetchIndexDDL") {
            for ddl in try await driver.fetchIndexDDL(table: "orders", schema: schema) { line(["index-ddl", ddl]) }
        }
        await attempt("fetchForeignKeys") {
            for key in try await driver.fetchForeignKeys(table: "orders", schema: schema) {
                line(["foreign-key", key.name, key.column, key.referencedTable, key.referencedColumn])
            }
            line(["all-foreign-keys", "\(try await driver.fetchAllForeignKeys(schema: schema).count)"])
        }
        await attempt("fetchCheckConstraints") {
            for check in try await driver.fetchCheckConstraints(table: "orders", schema: schema) {
                line(["check", check.name, check.expression, check.columns.joined(separator: ",")])
            }
        }
        await attempt("fetchTriggers") {
            for trigger in try await driver.fetchTriggers(table: "orders", schema: schema) {
                line(["trigger", trigger.name, trigger.timing, trigger.event, trigger.definition])
                line(["trigger-ddl", try await driver.fetchTriggerDDL(trigger)])
            }
            line(["all-triggers", "\(try await driver.fetchAllTriggers(schema: schema).count)"])
            line(["trigger-definition", try await driver.fetchTriggerDefinition(name: "orders_touch", table: "orders", schema: schema)])
        }
        await attempt("fetchTableDDL") {
            for table in ["orders", "order_view"] { line(["ddl", table, try await driver.fetchTableDDL(table: table, schema: schema)]) }
        }
        await attempt("fetchViewDefinition") {
            line(["view", try await driver.fetchViewDefinition(view: "order_totals", schema: schema)])
        }
        await attempt("fetchTableMetadata") {
            let metadata = try await driver.fetchTableMetadata(table: "orders", schema: schema)
            line(["metadata", metadata.comment, metadata.totalSize == nil ? "nil" : "sized"])
            line(["all-metadata", "\(try await driver.fetchAllTableMetadata(schema: schema).count)"])
            line(["approximate-rows", try await driver.fetchApproximateRowCount(table: "orders", schema: schema).map(String.init)])
            line(["relation-comment", try await driver.fetchRelationComment(table: "orders", schema: schema)])
        }
        await attempt("allTablesMetadataSQL") {
            guard let sql = driver.allTablesMetadataSQL(schema: schema) else { return }
            for row in try await driver.execute(query: sql).rows { line(["all-tables", row[safe: 1]?.asText, row[safe: 7]?.asText]) }
        }
        await attempt("fetchUserDefinedTypes") {
            for type in try await driver.fetchUserDefinedTypes(schema: schema).sorted(by: { $0.name < $1.name }) {
                line(["type", type.name, type.definition])
                line(["type-reload", try await driver.fetchUserDefinedType(type).definition])
            }
        }
        await attempt("fetchRoutines") {
            let routines = try await driver.fetchRoutines(schema: schema).filter { fixtureRoutines.contains($0.name) }
            for routine in routines.sorted(by: { $0.name < $1.name }) {
                line(["routine", routine.name, routine.argumentSignature, routine.returnType])
                line(["routine-ddl", try await driver.fetchRoutineDDL(routine)])
            }
            let targets = try await driver.debugTargets(schema: schema).filter { fixtureRoutines.contains($0.name) }
            line(["debug-targets", "\(targets.count)"])
        }
        await attempt("fetchSequences") {
            for sequence in try await driver.fetchSequences(schema: schema) { line(["sequence", sequence.name, sequence.ddl]) }
            for sequence in try await driver.fetchDependentSequences(table: "orders", schema: schema) {
                line(["dependent-sequence", sequence.name, sequence.ddl])
            }
        }
        await attempt("fetchDependentTypes") {
            for type in try await driver.fetchDependentTypes(table: "orders", schema: schema) {
                line(["dependent-type", type.name, type.labels.joined(separator: ",")])
            }
        }
        await attempt("fetchPartitions") {
            for partition in try await driver.fetchPartitionDetails(table: "events", schema: schema) {
                line(["partition", partition.name, partition.bound])
            }
        }
        await attempt("fetchSchemaDetails") {
            let details = try await driver.fetchSchemaDetails(name: schema)
            line(["schema-details", details?.owner, "\(details?.grants.count ?? -1)"])
        }
        await attempt("fetchPrincipals") {
            line(["principals", try await driver.fetchPrincipals().isEmpty ? "none" : "listed"])
        }
        await attempt("generateColumnReorderPlan") {
            let columns = try await driver.fetchColumns(table: "customers", schema: schema)
            let plan = try await driver.generateColumnReorderPlan(
                table: "customers",
                schema: schema,
                columns: [],
                desiredOrder: columns.map(\.name).reversed()
            )
            for statement in plan?.statements ?? [] { line(["reorder", statement]) }
        }
        await attempt("spatialRendering") {
            let result = try await driver.execute(query: "SELECT id, location, real_location FROM \"\(schema)\".places ORDER BY id")
            for row in result.rows { line(["places", row.map { $0.asText ?? "-" }.joined(separator: ";")]) }
        }
    }
}
