import Foundation
import TableProModels
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

    /// The text that was split, where each unit ends in it, and its engine, so the rest can be split again.
    private let source: String?
    private let unitEnds: [Int]
    private let databaseType: DatabaseType?

    public init(units: [Unit], unitKind: UnitKind) {
        self.init(units: units, unitKind: unitKind, session: nil, source: nil, unitEnds: [], databaseType: nil)
    }

    private init(
        units: [Unit],
        unitKind: UnitKind,
        session: SQLSessionLexicalFacts?,
        source: String?,
        unitEnds: [Int],
        databaseType: DatabaseType?
    ) {
        self.units = units
        self.unitKind = unitKind
        self.session = session
        self.source = source
        self.unitEnds = unitEnds
        self.databaseType = databaseType
    }

    public var isEmpty: Bool { units.isEmpty }

    /// Every request the run sends, a `GO n` batch counted `n` times.
    public var requestCount: Int {
        units.reduce(0) { $0 + max($1.repeatCount, 1) }
    }

    /// Redis speaks commands, not SQL, and its driver reads the whole text as one command.
    ///
    /// `session` is what the connection says about its own literals, such as PostgreSQL's
    /// `standard_conforming_strings`: with it off, `'a\';b'` is one literal, and the default reading would cut it.
    public static func plan(
        _ text: String,
        databaseType: DatabaseType,
        sendsBatchesWhole: Bool,
        session: SQLSessionLexicalFacts? = nil
    ) -> QueryScript {
        if databaseType == .redis {
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return QueryScript(units: command.isEmpty ? [] : [Unit(sql: command)], unitKind: .statement)
        }

        let grammar = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue,
            declared: nil,
            session: session
        ).execution
        let statements = SQLStatementScanner.executableStatements(in: text, grammar: grammar)

        guard sendsBatchesWhole else {
            return QueryScript(
                units: statements.map { Unit(sql: $0.sql) },
                unitKind: .statement,
                session: session,
                source: text,
                unitEnds: statements.map { $0.range.location + $0.range.length },
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
            unitKind: .batch
        )
    }

    /// The text after unit `index`, split again under `session`, for a statement that changed how the session reads
    /// literals: after `SET sql_mode = 'NO_BACKSLASH_ESCAPES'` a backslash no longer escapes a quote, so the split
    /// made before it ran no longer matches what the server will read. Nil when the script cannot be split again.
    public func replanned(after index: Int, session: SQLSessionLexicalFacts?) -> QueryScript? {
        guard unitKind == .statement, let source, let databaseType, unitEnds.indices.contains(index) else {
            return nil
        }
        let rest = (source as NSString).substring(from: unitEnds[index])
        return QueryScript.plan(rest, databaseType: databaseType, sendsBatchesWhole: false, session: session)
    }
}
