import Foundation

// INFORMATION_SCHEMA says NO for every view; sys.dm_exec_describe_first_result_set compiles without running.
public enum MSSQLViewSources {
    public enum Refusal: Equatable, Sendable {
        case notUpdatable
        case writesRunTriggers
        case readsSeveralTables
        case baseTableHidden
    }

    public enum Operation: String, CaseIterable, Sendable {
        case update
        case insert
        case delete
    }

    public struct BaseTable: Hashable, Sendable {
        // Set for a table on a linked server.
        public let server: String?
        public let database: String?
        public let schema: String
        public let name: String

        public init(server: String? = nil, database: String?, schema: String, name: String) {
            self.server = server
            self.database = database
            self.schema = schema
            self.name = name
        }
    }

    public struct ViewColumn: Equatable, Sendable {
        public let name: String
        public let baseColumn: String?
        public let acceptsWrites: Bool

        public init(name: String, baseColumn: String?, acceptsWrites: Bool) {
            self.name = name
            self.baseColumn = baseColumn
            self.acceptsWrites = acceptsWrites
        }
    }

    public struct BaseColumn: Equatable, Sendable {
        public let name: String
        public let isNullable: Bool
        // Nil also for a default whose text needs VIEW DEFINITION to read.
        public let defaultValue: String?
        public let hasDefault: Bool
        public let isIdentity: Bool
        public let isComputed: Bool
        // A rowversion or a GENERATED ALWAYS period column.
        public let isServerGenerated: Bool

        public init(
            name: String,
            isNullable: Bool,
            defaultValue: String?,
            hasDefault: Bool,
            isIdentity: Bool,
            isComputed: Bool,
            isServerGenerated: Bool
        ) {
            self.name = name
            self.isNullable = isNullable
            self.defaultValue = defaultValue
            self.hasDefault = hasDefault
            self.isIdentity = isIdentity
            self.isComputed = isComputed
            self.isServerGenerated = isServerGenerated
        }

        // A default the user cannot read still fills the column when an INSERT leaves it out.
        public var assignsValue: Bool {
            isIdentity || isServerGenerated || (hasDefault && defaultValue == nil)
        }

        public var acceptsWrites: Bool {
            !isComputed && !isIdentity && !isServerGenerated
        }
    }

    static let maxViewDepth = 8

    // MARK: - The view itself

    // sys.sql_expression_dependencies needs VIEW DEFINITION; sys.sql_dependencies does not but drops recreated views.
    // A schema-bound view has one sys.sql_expression_dependencies row per column; minor id 0 is the object.
    public static func viewFactsQuery(schema: String, view: String) -> String {
        let object = MSSQLStringLiteral.quoted(MSSQLSchemaQueries.bracketed(schema: schema, table: view))
        return """
            DECLARE @view int = OBJECT_ID(\(object));
            DECLARE @edges TABLE (referencing_id int NOT NULL, referenced_id int NOT NULL);
            IF EXISTS (SELECT 1 FROM sys.views WHERE object_id = @view)
            BEGIN
                INSERT INTO @edges (referencing_id, referenced_id)
                SELECT DISTINCT d.object_id, d.referenced_major_id
                FROM sys.sql_dependencies d
                JOIN sys.views r ON r.object_id = d.referenced_major_id;
                IF HAS_PERMS_BY_NAME(N'sys.sql_expression_dependencies', 'OBJECT', 'SELECT') = 1
                    INSERT INTO @edges (referencing_id, referenced_id)
                    SELECT d.referencing_id, d.referenced_id
                    FROM sys.sql_expression_dependencies d
                    JOIN sys.views r ON r.object_id = d.referenced_id
                    WHERE d.referenced_minor_id = 0
                        AND NOT EXISTS (
                            SELECT 1
                            FROM @edges e
                            WHERE e.referencing_id = d.referencing_id AND e.referenced_id = d.referenced_id
                        );
            END;
            WITH chain AS (
                SELECT v.object_id, 0 AS depth
                FROM sys.views v
                WHERE v.object_id = @view
                UNION ALL
                SELECT e.referenced_id, c.depth + 1
                FROM chain c
                JOIN @edges e ON e.referencing_id = c.object_id
                WHERE c.depth < \(maxViewDepth)
            )
            SELECT
                v.has_opaque_metadata,
                CASE WHEN EXISTS (
                    SELECT 1
                    FROM chain c
                    JOIN sys.triggers tr ON tr.parent_id = c.object_id
                    WHERE tr.is_instead_of_trigger = 1 AND tr.is_disabled = 0
                ) THEN 1 ELSE 0 END AS runs_instead_of_trigger
            FROM sys.views v
            WHERE v.object_id = @view
            """
    }

    public struct ViewFacts: Equatable, Sendable {
        public let hasOpaqueMetadata: Bool
        public let runsInsteadOfTrigger: Bool

        public init(hasOpaqueMetadata: Bool, runsInsteadOfTrigger: Bool) {
            self.hasOpaqueMetadata = hasOpaqueMetadata
            self.runsInsteadOfTrigger = runsInsteadOfTrigger
        }

        // Nil when no view of that name is visible to the user.
        public init?(rows: [[String?]]) {
            guard let row = rows.first else { return nil }
            self.init(hasOpaqueMetadata: row.cell(0) == "1", runsInsteadOfTrigger: row.cell(1) == "1")
        }

        public var refusal: Refusal? {
            // WITH VIEW_METADATA makes browse mode name the view in place of its base table.
            if hasOpaqueMetadata { return .baseTableHidden }
            if runsInsteadOfTrigger { return .writesRunTriggers }
            return nil
        }
    }

    // MARK: - Browse mode

    // Mode 1 is FOR BROWSE: base table and column per column, plus hidden key and rowversion rows of every table.
    public static func browseQuery(schema: String, view: String) -> String {
        let select = "SELECT * FROM \(MSSQLSchemaQueries.bracketed(schema: schema, table: view))"
        return """
            SELECT name, is_hidden, source_server, source_database, source_schema, source_table, source_column,
                is_updateable
            FROM sys.dm_exec_describe_first_result_set(\(MSSQLStringLiteral.quoted(select)), NULL, 1)
            ORDER BY column_ordinal
            """
    }

    public enum Source: Equatable, Sendable {
        case table(BaseTable)
        case refused(Refusal)
    }

    public struct BrowseFacts: Equatable, Sendable {
        public let columns: [ViewColumn]
        public let baseTables: [BaseTable]
        // View columns the probes write, one per base column, in view order.
        public let writableColumns: [String]

        public init(rows: [[String?]]) {
            var columns: [ViewColumn] = []
            var baseTables: [BaseTable] = []
            var writableColumns: [String] = []
            var probedBaseColumns: Set<String> = []
            for row in rows {
                // A view that no longer compiles yields error rows with no name.
                guard let name = row.cell(0) else { continue }
                let server = row.cell(2)
                if let schema = row.cell(4), let table = row.cell(5) {
                    let base = BaseTable(server: server, database: row.cell(3), schema: schema, name: table)
                    if !baseTables.contains(base) { baseTables.append(base) }
                }
                guard row.cell(1) != "1" else { continue }
                let baseColumn = server == nil ? row.cell(6) : nil
                let acceptsWrites = row.cell(7) == "1"
                columns.append(ViewColumn(name: name, baseColumn: baseColumn, acceptsWrites: acceptsWrites))
                if acceptsWrites, let baseColumn, probedBaseColumns.insert(baseColumn).inserted {
                    writableColumns.append(name)
                }
            }
            self.columns = columns
            self.baseTables = baseTables
            self.writableColumns = writableColumns
        }

        public var source: Source {
            guard baseTables.count == 1, let table = baseTables.first else {
                return .refused(baseTables.isEmpty ? .notUpdatable : .readsSeveralTables)
            }
            // Its key and columns live in another server's catalog.
            return table.server == nil ? .table(table) : .refused(.baseTableHidden)
        }
    }

    // MARK: - Operations

    public static func probesQuery(schema: String, view: String, writableColumns: [String]) -> String {
        let target = MSSQLSchemaQueries.bracketed(schema: schema, table: view)
        var probes: [(Operation, String)] = [(.delete, "DELETE FROM \(target) WHERE 1 = 0")]
        if let first = writableColumns.first.map(bracketedColumn) {
            let list = writableColumns.map(bracketedColumn).joined(separator: ", ")
            probes.append((.update, "UPDATE \(target) SET \(first) = \(first) WHERE 1 = 0"))
            probes.append((.insert, "INSERT INTO \(target) (\(list)) SELECT \(list) FROM \(target) WHERE 1 = 0"))
        }
        let values = probes
            .map { "('\($0.0.rawValue)', \(MSSQLStringLiteral.quoted($0.1)))" }
            .joined(separator: ",\n    ")
        return """
            SELECT p.operation, r.error_number
            FROM (VALUES
                \(values)
            ) AS p(operation, statement)
            CROSS APPLY sys.dm_exec_describe_first_result_set(p.statement, NULL, 0) r
            WHERE r.error_number IS NOT NULL
            """
    }

    // Browse mode names a table once however often the view joins it, so a self-join shows only as 4405 on DELETE.
    public static func refusal(probeRows: [[String?]]) -> Refusal? {
        let joins = probeRows.contains { $0.cell(0) == Operation.delete.rawValue && $0.cell(1) == "4405" }
        return joins ? .readsSeveralTables : nil
    }

    public static func allowedOperations(writableColumns: [String], probeRows: [[String?]]) -> Set<Operation> {
        var allowed: Set<Operation> = writableColumns.isEmpty ? [.delete] : Set(Operation.allCases)
        for row in probeRows {
            guard let operation = row.cell(0).flatMap(Operation.init(rawValue:)),
                  let number = row.cell(1).flatMap({ Int($0) }),
                  structuralErrors.contains(number)
            else { continue }
            allowed.remove(operation)
        }
        return allowed
    }

    // 11501 marks any compile error. 229 and 230 come with 11529 and wait for the save, as on a table.
    static let structuralErrors: Set<Int> = [
        208, // invalid object name
        264, // a column assigned twice
        271, // computed column
        272, // timestamp column
        4_403, // aggregate, DISTINCT, GROUP BY, PIVOT
        4_405, // the statement touches several base tables
        4_406, // derived or constant column
        4_426, // UNION
        8_102, // identity column
        11_501, // the batch has compile errors
        13_537, // GENERATED ALWAYS column
    ]

    // MARK: - Base table

    // Read in the base table's own database. sys.tables skips a view that browse mode stopped at.
    public static func baseColumnsQuery(_ table: BaseTable) -> String {
        let catalog = table.database.map { "[\(MSSQLSchemaQueries.escapeBracket($0))]." } ?? ""
        let object = MSSQLStringLiteral.quoted(
            catalog + MSSQLSchemaQueries.bracketed(schema: table.schema, table: table.name)
        )
        return """
            SELECT
                c.name,
                c.is_nullable,
                d.definition,
                CASE WHEN c.default_object_id <> 0 THEN 1 ELSE 0 END AS has_default,
                c.is_identity,
                c.is_computed,
                CASE
                    WHEN TYPE_NAME(c.system_type_id) = 'timestamp' THEN 1
                    WHEN c.generated_always_type > 0 THEN 1
                    ELSE 0
                END AS is_server_generated,
                ic.key_ordinal
            FROM \(catalog)sys.columns c
            JOIN \(catalog)sys.tables t ON t.object_id = c.object_id
            LEFT JOIN \(catalog)sys.default_constraints d ON d.object_id = c.default_object_id
            LEFT JOIN \(catalog)sys.indexes i ON i.object_id = c.object_id AND i.is_primary_key = 1
            LEFT JOIN \(catalog)sys.index_columns ic
                ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.column_id = c.column_id
            WHERE c.object_id = OBJECT_ID(\(object))
            ORDER BY c.column_id
            """
    }

    public struct BaseFacts: Equatable, Sendable {
        public let keyColumns: [String]
        public let columns: [BaseColumn]

        public init(keyColumns: [String], columns: [BaseColumn]) {
            self.keyColumns = keyColumns
            self.columns = columns
        }

        // Nil when no row comes back: OBJECT_ID is NULL for a table the user has no permission on.
        public init?(rows: [[String?]]) {
            var columns: [BaseColumn] = []
            var keyed: [(ordinal: Int, name: String)] = []
            for row in rows {
                guard let name = row.cell(0) else { continue }
                columns.append(BaseColumn(
                    name: name,
                    isNullable: row.cell(1) == "1",
                    defaultValue: row.cell(2),
                    hasDefault: row.cell(3) == "1",
                    isIdentity: row.cell(4) == "1",
                    isComputed: row.cell(5) == "1",
                    isServerGenerated: row.cell(6) == "1"
                ))
                if let ordinal = row.cell(7).flatMap({ Int($0) }) {
                    keyed.append((ordinal, name))
                }
            }
            guard !columns.isEmpty else { return nil }
            self.init(keyColumns: keyed.sorted { $0.ordinal < $1.ordinal }.map(\.name), columns: columns)
        }
    }

    private static func bracketedColumn(_ column: String) -> String {
        "[\(MSSQLSchemaQueries.escapeBracket(column))]"
    }
}

private extension Array where Element == String? {
    func cell(_ index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
