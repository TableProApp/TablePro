import Foundation

/// What TablePro knows about one engine's lexing: the grammar it splits with, and the facts it cannot settle alone.
///
/// A fact lands in ``undetermined`` for one of two reasons. Either the server decides it per session, as MySQL's
/// `NO_BACKSLASH_ESCAPES`, PostgreSQL's `standard_conforming_strings` and Dameng's `BACKSLASH_ESCAPE` do, or nobody has
/// measured it against a live server. Either way a gate reads both values, which is always the safe direction: an
/// extra reading can only raise the statement count and the tier. `scripts/probes/check-sql-lexical-grammar.sh` re-measures
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
        let bits = (0..<UInt64.bitWidth).map { SQLLexicalGrammar(rawValue: 1 << $0) }.filter { undetermined.contains($0) }
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
    /// out for the same reason: an engine that refuses one without it says so through its plugin. So is a CQL batch,
    /// which would read one statement where an unknown engine may run several. So are the two single body forms, which
    /// would cut the `BEGIN ... END` body of an engine that has the usual one. So is a statement inside another, which
    /// would make every `update` or `access` column an unknown engine names a write, and Snowflake's pipe operator,
    /// which would cut a statement at the `->>` that is JSON's operator on an unknown engine.
    public static let everyKnownReading: [SQLLexicalGrammar] = {
        var seen: Set<SQLLexicalGrammar> = []
        var result: [SQLLexicalGrammar] = []
        for typeId in profiles.keys.sorted() {
            guard let profile = profiles[typeId] else { continue }
            for reading in profile.readings {
                let unitless = reading.subtracting([
                    .plsqlBlocks, .delimiterDirective, .unterminatedStatements, .terminatedMergeStatements,
                    .sqlScriptBlocks, .cqlBatches, .atomicRoutineBodies, .triggerBodies,
                    .statementsAsValues, .bracketedStatementSources, .pipeOperatorChains,
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
    /// are operators. From its grammar: a routine's body is a literal or `BEGIN ATOMIC ... END`.
    static let postgreSQL: SQLLexicalGrammar = [
        .taggedDollarQuotes, .nestedBlockComments, .escapeStringPrefix, .carriageReturnEndsLineComments,
        .atomicRoutineBodies,
    ]

    /// CockroachDB, from its scanner: PostgreSQL's grammar, and a `b'...'` byte literal read by the routine that reads
    /// `e'...'`, so `b'\''` escapes. Not measured.
    static let cockroachDB: SQLLexicalGrammar = postgreSQL.union(.escapeBytesPrefix)

    /// MySQL 8.4.11 and MariaDB 11.8.9, measured: a backslash escapes in `'` and `"` strings and is literal in a
    /// backtick identifier, block comments do not nest, `#` is a comment, `/*! */` runs, `--` needs whitespace after
    /// it, and only a line feed ends a line comment.
    static let mySQL: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .hashLineComments,
        .executableComments, .dashCommentsNeedWhitespace, .delimiterDirective,
    ]

    /// SQLite 3.54, measured: brackets and backticks quote identifiers, `]]` does not escape, a backslash is literal,
    /// a Tcl-style `$name(...)` parameter swallows quotes and semicolons, and only a line feed ends `--`. From its
    /// grammar: only a trigger has a body.
    static let sqlite: SQLLexicalGrammar = [
        .backtickQuotes, .bracketQuotedIdentifiers, .parenthesizedParameterNames, .triggerBodies,
    ]

    /// DuckDB 1.5.2 and 1.5.4, measured: lexes strings, comments and dollar quotes as PostgreSQL does. It has no
    /// `BEGIN ... END` body, so it takes PostgreSQL's narrower fact.
    static let duckDB: SQLLexicalGrammar = [
        .taggedDollarQuotes, .nestedBlockComments, .escapeStringPrefix, .carriageReturnEndsLineComments,
        .atomicRoutineBodies,
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
    /// sent without its `;` fails the whole batch with Msg 10713. An exponent takes its sign with no digit after it:
    /// `1E+DELETE` runs the `DELETE`. Whether it takes the first `-` of a `--` that way is not measured.
    public static let sqlServer: SQLLexicalGrammar = [
        .bracketQuotedIdentifiers, .doubledClosingBracketEscapes, .nestedBlockComments,
        .carriageReturnEndsLineComments, .batchSeparatorLines, .unterminatedStatements, .terminatedMergeStatements,
        .hashAndAtInIdentifiers,
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
        .taggedDollarQuotes, .nestedBlockComments, .escapeStringPrefix, .atomicRoutineBodies,
    ]

    /// ClickHouse, from its syntax reference: a backslash escapes in strings and in both quoted identifier forms, `#`
    /// and `--` are comments, and `$heredoc$` bodies are literals. `//` is a comment too: the reference leaves it out,
    /// but its `Lexer.cpp` reads it to the end of the line and has no `//` operator, so no reading takes it for code.
    /// Not measured.
    static let clickHouse: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
        .backtickQuotes, .hashLineComments, .doubleSlashLineComments, .taggedDollarQuotes,
    ]

    /// Snowflake, from its reference: a backslash escapes in single-quoted strings, `$$` bodies are literals, `//`
    /// is a comment, and the pipe operator `->>` chains statements that run in order, so `SHOW TABLES ->> DROP TABLE t`
    /// runs both. Not measured.
    static let snowflake: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .untaggedDollarQuotes, .doubleSlashLineComments, .pipeOperatorChains,
    ]

    /// Databend, from its tokenizer: a backslash escapes in `'` and `"`, backticks quote identifiers, `$$` bodies
    /// are literals, and a form feed ends `--` as a line feed does. Not measured.
    static let databend: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .untaggedDollarQuotes,
        .formFeedEndsLineComments,
    ]

    /// CQL for Cassandra and ScyllaDB, from the reference: `$$` bodies are literals, `//` is a comment, and a
    /// `BEGIN BATCH ... APPLY BATCH` holds the `;` after each statement inside it. Not measured.
    static let cql: SQLLexicalGrammar = [.untaggedDollarQuotes, .doubleSlashLineComments, .cqlBatches]

    /// SurrealQL, from its reference and lexer: a backslash escapes in both quotes and in a backtick identifier, which
    /// has no doubled-backtick form and is how the plugin's `SurrealQL.quoteIdentifier` writes a name, `⟨⟩` quotes an
    /// identifier too, `#`, `//` and `--` are comments, and a statement is a value. Not measured.
    static let surrealQL: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
        .backtickQuotes, .angleQuotedIdentifiers, .backslashEscapesInAngleQuotes, .hashLineComments,
        .doubleSlashLineComments, .statementsAsValues,
    ]

    // Cypher, from the Neo4j manual: a backslash escapes in both quotes, backticks quote names, `//` is a comment and
    // `--` is a pattern. Not measured.
    static let cypher: SQLLexicalGrammar = [
        .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .doubleSlashLineComments,
        .withoutDashComments,
    ]

    /// DynamoDB, from the driver's statement forms: a request is `<Action> {JSON}`, and a backslash escapes inside a
    /// JSON string. PartiQL, the other form, documents only a doubled quote, so plain ANSI is kept as an alternative
    /// and a gate reads both. Not measured.
    static let dynamoDB: SQLLexicalGrammar = [.backslashEscapesInDoubleQuotes]

    static let sapHana: SQLLexicalGrammar = [.dollarAndHashInIdentifiers, .sqlScriptBlocks]

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
        let trinoFamily = SQLLexicalProfile(grammar: .ansi, undetermined: [.carriageReturnEndsLineComments])
        return [
            "PostgreSQL": postgreSQLFamily,
            "Greenplum": postgreSQLFamily,
            "AlloyDB": postgreSQLFamily,
            "Citus": postgreSQLFamily,
            "PGlite": postgreSQLFamily,
            "KingbaseES": SQLLexicalProfile(
                grammar: postgreSQL,
                undetermined: [
                    .backslashEscapesInSingleQuotes, .alternativeQuoting, .plsqlBlocks,
                    .slashLineTerminators, .dollarAndHashInIdentifiers,
                ]
            ),
            "Redshift": SQLLexicalProfile(
                grammar: postgreSQL,
                undetermined: [.backslashEscapesInSingleQuotes, .nestedBlockComments, .escapeStringPrefix]
            ),
            "CockroachDB": SQLLexicalProfile(
                grammar: cockroachDB.union(.bracketedStatementSources),
                undetermined: [.nestedBlockComments, .taggedDollarQuotes, .carriageReturnEndsLineComments]
            ),
            "MySQL": SQLLexicalProfile(
                grammar: mySQL,
                undetermined: [.backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .taggedDollarQuotes]
            ),
            "MariaDB": mySQLFamily,
            "TiDB": mySQLCompatible,
            "OceanBase": mySQLCompatible,
            "StarRocks": mySQLCompatible,
            "Databend": SQLLexicalProfile(
                grammar: databend,
                undetermined: [
                    .hashLineComments, .nestedBlockComments, .carriageReturnEndsLineComments, .formFeedEndsLineComments,
                ]
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
            "SQL Server": SQLLexicalProfile(grammar: sqlServer, undetermined: [.exponentSignsNeedNoDigits]),
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
            "Trino": trinoFamily,
            "Presto": trinoFamily,
            "Teradata": SQLLexicalProfile(
                grammar: .ansi,
                undetermined: [.nestedBlockComments, .carriageReturnEndsLineComments]
            ),
            "SAP HANA": SQLLexicalProfile(
                grammar: sapHana,
                undetermined: [.nestedBlockComments, .carriageReturnEndsLineComments]
            ),
            "Cassandra": cqlFamily,
            "ScyllaDB": cqlFamily,
            "DynamoDB": SQLLexicalProfile(
                grammar: dynamoDB,
                alternatives: [.ansi],
                undetermined: [.carriageReturnEndsLineComments]
            ),
            "SurrealDB": SQLLexicalProfile(
                grammar: surrealQL,
                undetermined: [
                    .backslashEscapesInBackticks, .backslashEscapesInAngleQuotes, .carriageReturnEndsLineComments,
                ]
            ),
            "Neo4j": SQLLexicalProfile(grammar: cypher, undetermined: [.carriageReturnEndsLineComments]),
            "Redis": commandLineFamily,
            "MongoDB": commandLineFamily,
            "etcd": commandLineFamily,
            "Elasticsearch": commandLineFamily,
            "Typesense": commandLineFamily,
            "Weaviate": commandLineFamily,
            "Qdrant": commandLineFamily,
            "Memcached": commandLineFamily,
            "Kafka": commandLineFamily,
            "Firestore": commandLineFamily,
            "Firebase Realtime Database": commandLineFamily,
            "Bigtable": commandLineFamily,
        ]
    }()
}
