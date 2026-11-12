import Foundation
import TableProModels
import TableProRedisCore
import TableProSQLGrammar

/// The requests one run of a query text makes, in the order it makes them.
///
/// A text sent whole runs one statement or reports one result on every engine the iOS app speaks: SQLite and DuckDB
/// compile one statement per prepare, MySQL is connected without multi-statement support, and libpq answers with one
/// result. So the text is split here, by the grammar the engine's own lexer follows, as the Mac splits it. A driver
/// that sends batches whole (SQL Server) gets its `GO` batches instead, because T-SQL scopes a variable to its batch.
public struct QueryScript: Sendable, Equatable {
    public enum UnitKind: Sendable, Equatable {
        case statement
        case batch
    }

    public struct Unit: Sendable, Equatable {
        public let sql: String

        /// How many times the script asks for the unit to run: `GO 5` runs its batch five times.
        public let repeatCount: Int

        public init(sql: String, repeatCount: Int = 1) {
            self.sql = sql
            self.repeatCount = repeatCount
        }
    }

    public let units: [Unit]
    public let unitKind: UnitKind

    /// How the session read literals when the text was split.
    public let session: SQLSessionLexicalFacts?

    /// The text that was split, the statement each unit runs, and its engine, so the rest can be split again.
    private let source: String?
    private let statements: [SQLStatementScanner.ExecutableStatement]
    private let databaseType: DatabaseType?

    public init(units: [Unit], unitKind: UnitKind) {
        self.init(units: units, unitKind: unitKind, session: nil, source: nil, statements: [], databaseType: nil)
    }

    private init(
        units: [Unit],
        unitKind: UnitKind,
        session: SQLSessionLexicalFacts?,
        source: String?,
        statements: [SQLStatementScanner.ExecutableStatement],
        databaseType: DatabaseType?
    ) {
        self.units = units
        self.unitKind = unitKind
        self.session = session
        self.source = source
        self.statements = statements
        self.databaseType = databaseType
    }

    public var isEmpty: Bool { units.isEmpty }

    /// Every request the run sends, a `GO n` batch counted `n` times.
    public var requestCount: Int {
        units.reduce(0) { $0 + max($1.repeatCount, 1) }
    }

    public static func plan(
        _ text: String,
        databaseType: DatabaseType,
        sendsBatchesWhole: Bool,
        session: SQLSessionLexicalFacts? = nil
    ) -> QueryScript {
        if databaseType == .redis {
            let commands = RedisCommandSplitter.commands(in: text)
            return QueryScript(units: commands.map { Unit(sql: $0.text) }, unitKind: .statement)
        }
        if databaseType == .mongodb {
            let source = text as NSString
            let units = JavaScriptStatementScanner.executableStatements(in: text).compactMap { statement -> Unit? in
                let range = statement.contentRange
                return range.length > 0 ? Unit(sql: source.substring(with: range)) : nil
            }
            return QueryScript(units: units, unitKind: .statement)
        }

        let grammar = executionGrammar(for: databaseType, session: session)
        let statements = SQLStatementScanner.executableStatements(in: text, grammar: grammar)

        guard sendsBatchesWhole else {
            return QueryScript(
                units: statements.map { Unit(sql: $0.sql) },
                unitKind: .statement,
                session: session,
                source: text,
                statements: statements,
                databaseType: databaseType
            )
        }
        let batches = SQLStatementScanner.batches(
            in: text,
            statements: statements,
            separators: SQLStatementScanner.batchSeparators(in: text, grammar: grammar)
        )
        return QueryScript(
            units: batches.map { Unit(sql: $0.sql, repeatCount: $0.repeatCount) },
            unitKind: .batch,
            session: session,
            source: nil,
            statements: [],
            databaseType: databaseType
        )
    }

    /// The statements a unit runs: the unit itself, or each statement of a batch, so a `ROLLBACK` after a `SELECT` in
    /// one `GO` batch still counts.
    public func statements(in unit: Unit) -> [String] {
        guard unitKind == .batch, let databaseType else { return [unit.sql] }
        let grammar = Self.executionGrammar(for: databaseType, session: session)
        return SQLStatementScanner.executableStatements(in: unit.sql, grammar: grammar).map(\.sql)
    }

    // A bare Redis argument may end in a byte Foundation trims, such as a vertical tab or a no-break space.
    public static func trimmed(_ text: String, databaseType: DatabaseType) -> String {
        guard databaseType == .redis else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let commands = RedisCommandSplitter.commands(in: text)
        guard let first = commands.first, let last = commands.last else { return "" }
        let start = first.range.location
        return (text as NSString).substring(with: NSRange(location: start, length: NSMaxRange(last.range) - start))
    }

    static func executionGrammar(for databaseType: DatabaseType, session: SQLSessionLexicalFacts?) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: databaseType.rawValue, declared: nil, session: session).execution
    }

    /// The text after unit `index`, split again under `session`, for a statement that changed how the session reads
    /// literals: after `SET sql_mode = 'NO_BACKSLASH_ESCAPES'` a backslash no longer escapes a quote, so the split
    /// made before it ran no longer matches what the server will read. Nil when the script cannot be split again.
    ///
    /// The rest starts where the scan went on after the unit, so a `COPY`'s rows stay rows and a client delimiter
    /// stays in force.
    public func replanned(after index: Int, session: SQLSessionLexicalFacts?) -> QueryScript? {
        guard unitKind == .statement, let source, let databaseType, statements.indices.contains(index) else {
            return nil
        }
        let rest = SQLStatementScanner.executableStatements(
            in: source,
            after: statements[index],
            through: (source as NSString).length,
            grammar: Self.executionGrammar(for: databaseType, session: session)
        )
        return QueryScript(
            units: rest.map { Unit(sql: $0.sql) },
            unitKind: .statement,
            session: session,
            source: source,
            statements: rest,
            databaseType: databaseType
        )
    }
}

extension JavaScriptStatementScanner.Statement {
    // The span the Mac's QueryStatementScanner runs for a JavaScript statement.
    var contentRange: NSRange {
        SQLStatementScanner.LocatedStatement(sql: text, offset: range.location, hasContent: hasContent).contentRange
    }
}
