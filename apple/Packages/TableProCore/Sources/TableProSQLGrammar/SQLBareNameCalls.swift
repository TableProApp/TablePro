import Foundation

// Oracle and Dameng call a function that takes no arguments when a query names it without parentheses, once the name
// is not a column of a table in scope. Measured on Oracle 23ai and DM8: a column wins; a correlated subquery sees the
// outer query's tables and an inline view does not; a select-list alias is seen by ORDER BY only; `pkg.f` and
// `owner.f` call; on Dameng `alias.f` calls package `alias` when its table has no column F. This reads every such name
// a query holds, and `SQLCallableCatalog` is what the session sees, so together they say whether the query calls one.
public enum SQLBareNameCalls {
    public static let engines: Set<String> = ["Oracle", "Dameng"]

    // Under every way the engine could lex the text. Only a query reads anything: a write is refused before this.
    public static func read(_ sql: String, databaseTypeId: String, readings: SQLLexicalReadings) -> SQLBareNameReading {
        let reserved = reservedWords(forDatabaseTypeId: databaseTypeId)
        var reading = SQLBareNameReading()
        reading.foldsFunctionNames = databaseTypeId == "Dameng"
        for grammar in readings.all {
            for statement in SQLStatementClassifier.statements(of: sql, grammar: grammar) {
                var parser = Parser(StatementCode(statement, grammar: grammar), grammar: grammar, reserved: reserved)
                parser.parse()
                reading.callsOutright = reading.callsOutright || parser.callsOutright
                if !parser.blocks.isEmpty { reading.queries.append(parser.blocks) }
            }
        }
        return reading
    }

    // V$RESERVED_WORDS with RESERVED = 'Y' on Oracle 23ai, and the ones of those DM8 reserves too. No function carries
    // one of these names unquoted, so none is asked about.
    static let oracleReservedWords: Set<String> = [
        "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "BETWEEN", "BY", "CHAR", "CHECK", "CLUSTER", "COMPRESS", "CONNECT",
        "CREATE", "DATE", "DECIMAL", "DEFAULT", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "EXCEPT", "EXCLUSIVE",
        "EXISTS", "FLOAT", "FOR", "FROM", "GRANT", "GROUP", "HAVING", "IDENTIFIED", "IN", "INDEX", "INSERT", "INTEGER",
        "INTERSECT", "INTO", "IS", "LIKE", "LOCK", "LONG", "MINUS", "MODE", "NOCOMPRESS", "NOT", "NOWAIT", "NULL",
        "NUMBER", "OF", "ON", "OPTION", "OR", "ORDER", "PCTFREE", "PRIOR", "PUBLIC", "RAW", "RENAME", "RESOURCE",
        "REVOKE", "SELECT", "SET", "SHARE", "SIZE", "SMALLINT", "START", "SYNONYM", "TABLE", "THEN", "TO", "TRIGGER",
        "UNION", "UNIQUE", "UPDATE", "VALUES", "VARCHAR", "VARCHAR2", "VIEW", "WHERE", "WITH",
    ]

    static let damengReservedWords: Set<String> = oracleReservedWords.subtracting([
        "COMPRESS", "DATE", "EXCEPT", "EXCLUSIVE", "IDENTIFIED", "INTEGER", "LOCK", "LONG", "MODE", "NOCOMPRESS",
        "NOWAIT", "NUMBER", "OPTION", "PCTFREE", "RAW", "RENAME", "RESOURCE", "SHARE", "SIZE", "SMALLINT", "THEN",
        "VARCHAR", "VARCHAR2",
    ])

    static func reservedWords(forDatabaseTypeId typeId: String) -> Set<String> {
        typeId == "Dameng" ? damengReservedWords : oracleReservedWords
    }
}

public struct SQLTableName: Hashable, Sendable {
    // Nil resolves as the session does: the current schema, its synonyms, then public synonyms.
    public let owner: String?
    public let name: String

    public init(owner: String?, name: String) {
        self.owner = owner
        self.name = name
    }
}

// What the session can call bare, read once per connection and schema with `query`.
public struct SQLCallableCatalog: Sendable, Equatable {
    // Functions in the current schema and synonyms that reach a function, a synonym or a remote object.
    public let functions: Set<String>
    // What a dotted call can start with: packages and synonyms to them, and schemas.
    public let roots: Set<String>

    public init(functions: Set<String>, roots: Set<String>) {
        self.functions = functions
        self.roots = roots
    }

    // Rows of `query`: a kind, `F` or `R`, and a name.
    public init(rows: [[String?]]) {
        var functions: Set<String> = []
        var roots: Set<String> = []
        for row in rows where row.count >= 2 {
            guard let kind = row[0], let name = row[1] else { continue }
            if kind == "F" { functions.insert(name) } else if kind == "R" { roots.insert(name) }
        }
        self.init(functions: functions, roots: roots)
    }

    // Owners are named, since a schema object called ALL_OBJECTS would otherwise answer instead. Oracle and DM8 both
    // answer it.
    public static let query = """
        SELECT 'F', o.OBJECT_NAME FROM SYS.ALL_OBJECTS o
         WHERE o.OWNER = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AND o.OBJECT_TYPE = 'FUNCTION'
        UNION
        SELECT 'F', s.SYNONYM_NAME FROM SYS.ALL_SYNONYMS s
         WHERE s.OWNER IN (SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'), 'PUBLIC')
           AND (s.DB_LINK IS NOT NULL OR EXISTS (SELECT 1 FROM SYS.ALL_OBJECTS t WHERE t.OWNER = s.TABLE_OWNER
                AND t.OBJECT_NAME = s.TABLE_NAME AND t.OBJECT_TYPE IN ('FUNCTION', 'SYNONYM')))
        UNION
        SELECT 'R', o.OBJECT_NAME FROM SYS.ALL_OBJECTS o
         WHERE o.OWNER = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') AND o.OBJECT_TYPE = 'PACKAGE'
        UNION
        SELECT 'R', s.SYNONYM_NAME FROM SYS.ALL_SYNONYMS s
         WHERE s.OWNER IN (SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'), 'PUBLIC')
           AND (s.DB_LINK IS NOT NULL OR EXISTS (SELECT 1 FROM SYS.ALL_OBJECTS t WHERE t.OWNER = s.TABLE_OWNER
                AND t.OBJECT_NAME = s.TABLE_NAME AND t.OBJECT_TYPE IN ('PACKAGE', 'SYNONYM')))
        UNION
        SELECT 'R', u.USERNAME FROM SYS.ALL_USERS u
        """

    // The columns of each table as the session resolves its name: an object in the schema first, then a synonym there,
    // then, for a name without an owner, a public synonym. Rows: the table's position, the rank, the database link and
    // a column. Nil when a name cannot be written as a literal.
    public static func columnsQuery(for tables: [SQLTableName]) -> String? {
        var branches: [String] = []
        for (index, table) in tables.enumerated() {
            guard let name = literal(table.name) else { return nil }
            let owner: String
            if let tableOwner = table.owner {
                guard let quoted = literal(tableOwner) else { return nil }
                owner = quoted
            } else {
                owner = "SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')"
            }
            branches.append("""
                SELECT \(index) I, 1 R, o.OWNER, o.OBJECT_NAME N, CAST(NULL AS VARCHAR2(128)) L FROM SYS.ALL_OBJECTS o \
                WHERE o.OWNER = \(owner) AND o.OBJECT_NAME = \(name) \
                AND o.OBJECT_TYPE IN ('TABLE', 'VIEW', 'MATERIALIZED VIEW')
                """)
            branches.append("""
                SELECT \(index), 2, s.TABLE_OWNER, s.TABLE_NAME, s.DB_LINK FROM SYS.ALL_SYNONYMS s \
                WHERE s.OWNER = \(owner) AND s.SYNONYM_NAME = \(name)
                """)
            if table.owner == nil {
                branches.append("""
                    SELECT \(index), 3, s.TABLE_OWNER, s.TABLE_NAME, s.DB_LINK FROM SYS.ALL_SYNONYMS s \
                    WHERE s.OWNER = 'PUBLIC' AND s.SYNONYM_NAME = \(name)
                    """)
            }
        }
        guard !branches.isEmpty else { return nil }
        return """
            SELECT t.I, t.R, t.L, c.COLUMN_NAME FROM (\(branches.joined(separator: " UNION ALL "))) t \
            LEFT JOIN SYS.ALL_TAB_COLUMNS c ON c.OWNER = t.OWNER AND c.TABLE_NAME = t.N
            """
    }

    // The first rank that resolves wins. A synonym to a remote object, or to another synonym, has no columns here.
    public static func columns(fromRows rows: [[String?]], tables: [SQLTableName]) -> [SQLTableName: Set<String>] {
        var ranked: [Int: (rank: Int, remote: Bool, columns: Set<String>)] = [:]
        for row in rows where row.count >= 4 {
            guard let index = row[0].flatMap({ Int($0) }), tables.indices.contains(index),
                  let rank = row[1].flatMap({ Int($0) })
            else { continue }
            let remote = row[2].map { !$0.isEmpty } ?? false
            if let current = ranked[index], current.rank < rank { continue }
            var entry = ranked[index].flatMap { $0.rank == rank ? $0 : nil }
                ?? (rank: rank, remote: remote, columns: Set<String>())
            entry.remote = entry.remote || remote
            if let column = row[3] { entry.columns.insert(column) }
            ranked[index] = entry
        }
        var columns: [SQLTableName: Set<String>] = [:]
        for (index, entry) in ranked where !entry.remote {
            columns[tables[index]] = entry.columns
        }
        return columns
    }

    // A backslash escapes the quote on a DM8 server with BACKSLASH_ESCAPE set, so a name holding one is not written.
    private static func literal(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return "'" + name.replacingOccurrences(of: "'", with: "''", options: .literal) + "'"
    }
}

// The names a query holds outside parentheses, block by block, before the catalog says which ones call.
public struct SQLBareNameReading: Sendable, Equatable {
    // A dotted name that no table in scope starts, such as `pkg.f` or `owner.f`, or a name at a database link: a call,
    // or an error the engine raises before it runs anything.
    public internal(set) var callsOutright = false
    var queries: [[SQLBareNameBlock]] = []
    // A DM8 instance set up with CASE_SENSITIVE=N keeps a name as written, so on Dameng a function or root matches in
    // any case. Columns still match exactly, which can only count more names as calls.
    var foldsFunctionNames = false

    // Nothing in the query could be a function's name.
    public var namesNothing: Bool {
        !callsOutright && queries.allSatisfy { blocks in blocks.allSatisfy(\.candidates.isEmpty) }
    }

    // The tables whose columns decide, once the catalog holds a name the query uses. Empty when none does.
    public func tablesToResolve(_ catalog: SQLCallableCatalog) -> Set<SQLTableName> {
        let catalog = matching(catalog)
        var tables: Set<SQLTableName> = []
        for blocks in queries where blocks.contains(where: { $0.namesSomething(in: catalog, folding: foldsFunctionNames) }) {
            for block in blocks {
                for case .table(let table, _) in block.sources { tables.insert(table) }
            }
        }
        return tables
    }

    // `columns` holds what `SQLCallableCatalog.columns(fromRows:tables:)` read. A table missing from it has columns
    // nobody knows, so a name it might hold counts as a call.
    public func callsFunction(_ catalog: SQLCallableCatalog, columns: [SQLTableName: Set<String>]) -> Bool {
        if callsOutright { return true }
        let catalog = matching(catalog)
        return queries.contains { blocks in
            let resolver = SQLBareNameResolver(blocks: blocks, columns: columns, folding: foldsFunctionNames)
            return blocks.indices.contains { resolver.blockCalls($0, catalog: catalog) }
        }
    }

    private func matching(_ catalog: SQLCallableCatalog) -> SQLCallableCatalog {
        guard foldsFunctionNames else { return catalog }
        return SQLCallableCatalog(
            functions: Set(catalog.functions.map { $0.uppercased() }),
            roots: Set(catalog.roots.map { $0.uppercased() })
        )
    }
}

struct SQLBareNameBlock: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case table(SQLTableName, alias: String?)
        // An inline view or a common table expression. Nil block: one that refers to itself, read by its column list.
        case derived(block: Int?, columns: [String]?, alias: String?)
        // `TABLE(...)`, `JSON_TABLE(...)`, a pipelined function, a remote table, a pivot: columns nobody knows.
        case opaque(alias: String?)

        var alias: String? {
            switch self {
            case .table(_, let alias), .derived(_, _, let alias), .opaque(let alias): return alias
            }
        }

        // The name a qualifier can use: the alias, or else the table's own name.
        func answers(to qualifier: String) -> Bool {
            if let alias { return alias == qualifier }
            if case .table(let table, _) = self { return table.name == qualifier }
            return false
        }
    }

    enum Output: Sendable, Equatable {
        case name(String)
        case all
        case allOf(String)
    }

    enum Candidate: Sendable, Equatable {
        // `seesAliases`: an ORDER BY name, which resolves to a select-list alias first.
        case name(String, seesAliases: Bool)
        // `root.member` where a table in scope answers to `root`.
        case member(root: String, member: String)
    }

    var parent: Int?
    var sources: [Source] = []
    var aliases: Set<String> = []
    var outputs: [Output] = []
    var candidates: [Candidate] = []
    // A compound query's trailing ORDER BY sees only its first branch's names.
    var orderByNamesOf: Int?
    // Dotted names, resolved once every block's tables are read.
    var chains: [[String]] = []

    func namesSomething(in catalog: SQLCallableCatalog, folding: Bool) -> Bool {
        candidates.contains { candidate in
            switch candidate {
            case .name(let name, _): return catalog.functions.contains(folding ? name.uppercased() : name)
            case .member(let root, _): return catalog.roots.contains(folding ? root.uppercased() : root)
            }
        }
    }
}

private struct SQLBareNameResolver {
    let blocks: [SQLBareNameBlock]
    let columns: [SQLTableName: Set<String>]
    let folding: Bool

    func blockCalls(_ index: Int, catalog: SQLCallableCatalog) -> Bool {
        let block = blocks[index]
        return block.candidates.contains { candidate in
            switch candidate {
            case .name(let name, let seesAliases):
                guard catalog.functions.contains(folding ? name.uppercased() : name) else { return false }
                if seesAliases {
                    if let named = block.orderByNamesOf {
                        return outputNames(of: named, depth: 0)?.contains(name) != true
                    }
                    if block.aliases.contains(name) { return false }
                }
                return !isColumn(name, from: index)
            case .member(let root, let member):
                guard catalog.roots.contains(folding ? root.uppercased() : root) else { return false }
                guard let source = source(answering: root, from: index) else { return true }
                return columns(of: source, depth: 0)?.contains(member) != true
            }
        }
    }

    private func isColumn(_ name: String, from index: Int) -> Bool {
        var current: Int? = index
        var hops = 0
        while let blockIndex = current, hops <= blocks.count {
            if blocks[blockIndex].sources.contains(where: { columns(of: $0, depth: 0)?.contains(name) == true }) {
                return true
            }
            current = blocks[blockIndex].parent
            hops += 1
        }
        return false
    }

    private func source(answering qualifier: String, from index: Int) -> SQLBareNameBlock.Source? {
        var current: Int? = index
        var hops = 0
        while let blockIndex = current, hops <= blocks.count {
            if let source = blocks[blockIndex].sources.first(where: { $0.answers(to: qualifier) }) { return source }
            current = blocks[blockIndex].parent
            hops += 1
        }
        return nil
    }

    private func columns(of source: SQLBareNameBlock.Source, depth: Int) -> Set<String>? {
        guard depth <= SQLStatementTiering.deepestNesting else { return nil }
        switch source {
        case .table(let table, _):
            return columns[table]
        case .derived(let block, let explicit, _):
            if let explicit { return Set(explicit) }
            return block.flatMap { outputNames(of: $0, depth: depth + 1) }
        case .opaque:
            return nil
        }
    }

    private func outputNames(of index: Int, depth: Int) -> Set<String>? {
        guard blocks.indices.contains(index), depth <= SQLStatementTiering.deepestNesting else { return nil }
        let block = blocks[index]
        var names: Set<String> = []
        for output in block.outputs {
            switch output {
            case .name(let name):
                names.insert(name)
            case .all:
                for source in block.sources {
                    guard let sourceColumns = columns(of: source, depth: depth + 1) else { return nil }
                    names.formUnion(sourceColumns)
                }
            case .allOf(let qualifier):
                guard let source = block.sources.first(where: { $0.answers(to: qualifier) }),
                      let sourceColumns = columns(of: source, depth: depth + 1)
                else { return nil }
                names.formUnion(sourceColumns)
            }
        }
        return names
    }
}
