import Foundation

/// What TablePro knows about one engine's lexing: the grammar it splits with, and the facts it cannot settle alone.
///
/// A fact lands in ``undetermined`` for one of two reasons. Either the server decides it per session, as MySQL's
/// `NO_BACKSLASH_ESCAPES`, PostgreSQL's `standard_conforming_strings` and Dameng's `BACKSLASH_ESCAPE` do, or nobody has
/// measured it against a live server. Either way a gate reads both values, which is always the safe direction: an
/// extra reading can only raise the statement count and the tier. `scripts/check-sql-lexical-grammar.sh` re-measures
/// the facts marked measured below.
public struct SQLLexicalProfile: Sendable, Hashable {
    public let grammar: SQLLexicalGrammar

    /// Whole grammars the engine may be running instead of ``grammar``, as Spanner does per database.
    public let alternatives: [SQLLexicalGrammar]

    public let undetermined: SQLLexicalGrammar

    /// Every combination of the undetermined facts over ``grammar`` and each alternative, ``grammar`` first.
    public let readings: [SQLLexicalGrammar]

    public init(
        grammar: SQLLexicalGrammar,
        alternatives: [SQLLexicalGrammar] = [],
        undetermined: SQLLexicalGrammar = []
    ) {
        self.grammar = grammar
        self.alternatives = alternatives
        self.undetermined = undetermined
        self.readings = Self.readings(of: grammar, alternatives: alternatives, undetermined: undetermined)
    }

    private static func readings(
        of grammar: SQLLexicalGrammar,
        alternatives: [SQLLexicalGrammar],
        undetermined: SQLLexicalGrammar
    ) -> [SQLLexicalGrammar] {
        let bits = (0..<32).map { SQLLexicalGrammar(rawValue: 1 << $0) }.filter { undetermined.contains($0) }
        var subsets: [SQLLexicalGrammar] = [[]]
        for bit in bits {
            subsets += subsets.map { $0.union(bit) }
        }
        var seen: Set<SQLLexicalGrammar> = [grammar]
        var result = [grammar]
        for base in [grammar] + alternatives {
            for subset in subsets {
                let reading = base.subtracting(undetermined).union(subset)
                if seen.insert(reading).inserted {
                    result.append(reading)
                }
            }
        }
        return result
    }

    public static func curated(forDatabaseTypeId typeId: String) -> SQLLexicalProfile? {
        profiles[typeId]
    }

    /// The database type ids the curated table covers.
    public static var curatedDatabaseTypeIds: Set<String> {
        Set(profiles.keys)
    }

    /// Every reading of every curated engine, the readings a gate has to take for an engine it knows nothing about.
    /// A PL/SQL unit grammar is left out: it chooses statement boundaries rather than token rules, and an unknown
    /// engine keeps the routine-body boundaries every non-Oracle engine has. So is T-SQL's statement that needs no
    /// terminator, which would make every `open`, `close` or `return` column an unknown engine names a statement of its
    /// own; an engine that runs statements without one says so through its plugin. A `MERGE` that keeps its `;` is left
    /// out for the same reason: an engine that refuses one without it says so through its plugin.
    public static let everyKnownReading: [SQLLexicalGrammar] = {
        var seen: Set<SQLLexicalGrammar> = []
        var result: [SQLLexicalGrammar] = []
        for typeId in profiles.keys.sorted() {
            guard let profile = profiles[typeId] else { continue }
            for reading in profile.readings {
                let unitless = reading.subtracting([
                    .plsqlBlocks, .delimiterDirective, .unterminatedStatements, .terminatedMergeStatements,
                ])
                if seen.insert(unitless).inserted {
                    result.append(unitless)
                }
            }
        }
        return result
    }()

    // MARK: - Grammars

    /// PostgreSQL 17.11, measured: a backslash is literal under `standard_conforming_strings`, block comments nest,
    /// `$tag$` takes non-ASCII and case-sensitive tags, `E'\''` escapes, a carriage return ends `--`, and `#` and `//`
    /// are operators.
    static let postgreSQL: SQLLexicalGrammar = [
        .taggedDollarQuotes, .nestedBlockComments, .escapeStringPrefix, .carriageReturnEndsLineComments,
    ]

    /// MySQL 8.4.11 and MariaDB 11.8.9, measured: a backslash escapes in `'` and `"` strings and is literal in a
    /// backtick identifier, block comments do not nest, `#` is a comment, `/*! */` runs, `--` needs whitespace after
    /// it, and only a line feed ends a line comment.
    static let mySQL: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .hashLineComments,
        .executableComments, .dashCommentsNeedWhitespace, .delimiterDirective,
    ]

    /// SQLite 3.54, measured: brackets and backticks quote identifiers, `]]` does not escape, a backslash is literal,
    /// a Tcl-style `$name(...)` parameter swallows quotes and semicolons, and only a line feed ends `--`.
    static let sqlite: SQLLexicalGrammar = [
        .backtickQuotes, .bracketQuotedIdentifiers, .parenthesizedParameterNames,
    ]

    /// DuckDB 1.5.2 and 1.5.4, measured: lexes strings, comments and dollar quotes as PostgreSQL does.
    static let duckDB: SQLLexicalGrammar = [
        .taggedDollarQuotes, .nestedBlockComments, .escapeStringPrefix, .carriageReturnEndsLineComments,
    ]

    /// Oracle 23.26, measured: a backslash is literal, block comments do not nest, `q'[...]'` is a literal, `$` and
    /// `#` continue an identifier, and only a line feed ends `--`.
    static let oracle: SQLLexicalGrammar = [
        .alternativeQuoting, .slashLineTerminators, .dollarAndHashInIdentifiers, .plsqlBlocks,
    ]

    /// DM8 V8, measured in compatibility modes 0, 2, 4 and 7: `q'[...]'` is a literal, `//` is a comment, block
    /// comments do not nest, `$` and `#` continue an identifier, a carriage return ends a line comment, and a
    /// backslash is literal unless the server runs with `BACKSLASH_ESCAPE = 1`, which the plugin detects at connect.
    static let dameng: SQLLexicalGrammar = [
        .alternativeQuoting, .doubleSlashLineComments, .dollarAndHashInIdentifiers, .carriageReturnEndsLineComments,
    ]

    /// Azure SQL Edge 15.0 (the SQL Server 2019 engine), measured: brackets quote identifiers and `]]` escapes, block
    /// comments nest, a backslash is literal, a carriage return ends `--`, and T-SQL has no `$$`, `#` or `//` comment.
    /// A `GO` line is sqlcmd's, not the server's: sent to it, Azure SQL Edge answers Msg 102 and runs nothing. A
    /// statement needs no `;`: `SELECT 1` followed by `DROP TABLE t` runs both. A `MERGE` is the exception, and one
    /// sent without its `;` fails the whole batch with Msg 10713.
    static let sqlServer: SQLLexicalGrammar = [
        .bracketQuotedIdentifiers, .doubledClosingBracketEscapes, .nestedBlockComments,
        .carriageReturnEndsLineComments, .batchSeparatorLines, .unterminatedStatements, .terminatedMergeStatements,
    ]

    /// Spanner's GoogleSQL dialect on the emulator, measured, and BigQuery by the ZetaSQL grammar the two share: a
    /// backslash escapes in every quote including backticks, `'''` and `"""` literals, `#` comments, flat block
    /// comments.
    static let googleSQL: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
        .backtickQuotes, .tripleQuotedStrings, .hashLineComments,
    ]

    /// Spanner's PostgreSQL dialect on the emulator, measured: lexes as PostgreSQL does.
    static let spannerPostgreSQL: SQLLexicalGrammar = [
        .taggedDollarQuotes, .nestedBlockComments, .escapeStringPrefix,
    ]

    /// ClickHouse, from its syntax reference: a backslash escapes in strings and in both quoted identifier forms, `#`
    /// and `--` are comments, and `$heredoc$` bodies are literals. Not measured.
    static let clickHouse: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
        .backtickQuotes, .hashLineComments, .taggedDollarQuotes,
    ]

    /// Snowflake, from its reference: a backslash escapes in single-quoted strings, `$$` bodies are literals and `//`
    /// is a comment. Not measured.
    static let snowflake: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .untaggedDollarQuotes, .doubleSlashLineComments,
    ]

    /// Databend, from its tokenizer: a backslash escapes in `'` and `"`, backticks quote identifiers and `$$` bodies
    /// are literals. Not measured.
    static let databend: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .untaggedDollarQuotes,
    ]

    /// CQL for Cassandra and ScyllaDB, from the reference: `$$` bodies are literals and `//` is a comment. Not
    /// measured.
    static let cql: SQLLexicalGrammar = [.untaggedDollarQuotes, .doubleSlashLineComments]

    /// SurrealQL, from its reference: a backslash escapes in both quotes, and `#`, `//` and `--` are comments. Not
    /// measured.
    static let surrealQL: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .hashLineComments,
        .doubleSlashLineComments,
    ]

    /// DynamoDB, from the driver's statement forms: a request is `<Action> {JSON}`, and a backslash escapes inside a
    /// JSON string. PartiQL, the other form, documents only a doubled quote, so plain ANSI is kept as an alternative
    /// and a gate reads both. Not measured.
    static let dynamoDB: SQLLexicalGrammar = [.backslashEscapesInDoubleQuotes]

    /// Engines whose statements are commands or JSON documents rather than SQL. Their splitting is what it has always
    /// been: a backslash escapes inside any quote, as it does in JSON and in `redis-cli`.
    static let commandLine: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
        .backtickQuotes,
    ]

    private static let profiles: [String: SQLLexicalProfile] = {
        let postgreSQLFamily = SQLLexicalProfile(grammar: postgreSQL, undetermined: [.backslashEscapesInSingleQuotes])
        let mySQLFamily = SQLLexicalProfile(
            grammar: mySQL,
            undetermined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes]
        )
        let mySQLCompatible = SQLLexicalProfile(
            grammar: mySQL,
            undetermined: [
                .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .dashCommentsNeedWhitespace,
                .executableComments, .carriageReturnEndsLineComments,
            ]
        )
        let sqliteFamily = SQLLexicalProfile(grammar: sqlite)
        let cqlFamily = SQLLexicalProfile(grammar: cql, undetermined: [.carriageReturnEndsLineComments])
        let commandLineFamily = SQLLexicalProfile(grammar: commandLine)
        return [
            "PostgreSQL": postgreSQLFamily,
            "Greenplum": postgreSQLFamily,
            "AlloyDB": postgreSQLFamily,
            "Citus": postgreSQLFamily,
            "PGlite": postgreSQLFamily,
            "Redshift": SQLLexicalProfile(
                grammar: postgreSQL,
                undetermined: [.backslashEscapesInSingleQuotes, .nestedBlockComments, .escapeStringPrefix]
            ),
            "CockroachDB": SQLLexicalProfile(
                grammar: postgreSQL,
                undetermined: [.nestedBlockComments, .taggedDollarQuotes, .carriageReturnEndsLineComments]
            ),
            "MySQL": SQLLexicalProfile(
                grammar: mySQL,
                undetermined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .taggedDollarQuotes]
            ),
            "MariaDB": mySQLFamily,
            "TiDB": mySQLCompatible,
            "OceanBase": mySQLCompatible,
            "Databend": SQLLexicalProfile(
                grammar: databend,
                undetermined: [.hashLineComments, .nestedBlockComments, .carriageReturnEndsLineComments]
            ),
            "SQLite": sqliteFamily,
            "libSQL": sqliteFamily,
            "Turso": sqliteFamily,
            "Cloudflare D1": sqliteFamily,
            "DuckDB": SQLLexicalProfile(grammar: duckDB),
            "Oracle": SQLLexicalProfile(grammar: oracle),
            "Dameng": SQLLexicalProfile(
                grammar: dameng,
                undetermined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes]
            ),
            "SQL Server": SQLLexicalProfile(grammar: sqlServer),
            "ClickHouse": SQLLexicalProfile(
                grammar: clickHouse,
                undetermined: [.nestedBlockComments, .taggedDollarQuotes, .carriageReturnEndsLineComments]
            ),
            "Snowflake": SQLLexicalProfile(
                grammar: snowflake,
                undetermined: [.nestedBlockComments, .carriageReturnEndsLineComments]
            ),
            "BigQuery": SQLLexicalProfile(grammar: googleSQL, undetermined: [.carriageReturnEndsLineComments]),
            "Spanner": SQLLexicalProfile(
                grammar: googleSQL,
                alternatives: [spannerPostgreSQL],
                undetermined: [.carriageReturnEndsLineComments]
            ),
            "Trino": SQLLexicalProfile(grammar: .ansi, undetermined: [.carriageReturnEndsLineComments]),
            "Teradata": SQLLexicalProfile(
                grammar: .ansi,
                undetermined: [.nestedBlockComments, .carriageReturnEndsLineComments]
            ),
            "Cassandra": cqlFamily,
            "ScyllaDB": cqlFamily,
            "DynamoDB": SQLLexicalProfile(
                grammar: dynamoDB,
                alternatives: [.ansi],
                undetermined: [.carriageReturnEndsLineComments]
            ),
            "SurrealDB": SQLLexicalProfile(grammar: surrealQL, undetermined: [.carriageReturnEndsLineComments]),
            "Redis": commandLineFamily,
            "MongoDB": commandLineFamily,
            "etcd": commandLineFamily,
            "Elasticsearch": commandLineFamily,
            "Typesense": commandLineFamily,
            "Weaviate": commandLineFamily,
            "Kafka": commandLineFamily,
        ]
    }()
}
