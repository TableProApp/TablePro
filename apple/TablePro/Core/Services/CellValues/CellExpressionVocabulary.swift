//
//  CellExpressionVocabulary.swift
//  TablePro
//

import Foundation

enum CellExpressionKind: Hashable, Sendable {
    case timestamp
    case datetime
    case date
    case time
    case timeUUID

    init?(columnType: ColumnType) {
        if columnType.isTimeUUIDType {
            self = .timeUUID
            return
        }
        switch columnType {
        case .date:
            self = .date
        case .timestamp:
            self = columnType.isTimeOnly ? .time : .timestamp
        case .datetime:
            self = columnType.isTimeOnly ? .time : .datetime
        default:
            return nil
        }
    }
}

struct CellExpression: Hashable, Sendable {
    /// Written into the statement exactly as spelled here.
    let sql: String
    let kinds: Set<CellExpressionKind>
    /// Other spellings typed into a cell that mean this expression; each one is written as `sql`.
    let aliases: [String]

    init(_ sql: String, kinds: Set<CellExpressionKind>, aliases: [String] = []) {
        self.sql = sql
        self.kinds = kinds
        self.aliases = aliases
    }

    func matches(typed text: String) -> Bool {
        sql.caseInsensitiveCompare(text) == .orderedSame
            || aliases.contains { $0.caseInsensitiveCompare(text) == .orderedSame }
    }
}

/// The SQL a cell may be set to, keyed by database type the way `ColumnDefaultVocabulary` is.
///
/// Every entry was run against the engine or read from its DML reference, per column kind: the same name is a
/// syntax error on one engine and a type error on another kind of column (PostgreSQL rejects `CURRENT_TIMESTAMP()`,
/// SQLite has no `NOW()`, ClickHouse spells `today()` in lowercase only). Aliases are the spellings that saved before
/// the vocabulary existed and still run on that engine, so typed text keeps working. An unlisted engine gets nothing,
/// since `DatabaseType` is open.
enum CellExpressionVocabulary {
    static func expressions(for databaseType: DatabaseType) -> [CellExpression] {
        switch databaseType {
        case .postgresql, .pglite, .kingbasees: postgreSQL
        case .cockroachdb: cockroachDB
        case .redshift: redshift
        case .mysql, .mariadb, .tidb, .oceanbase: mySQL
        case .databend: databend
        case .sqlite, .libsql, .turso, .cloudflareD1: sqlite
        case .duckdb: duckDB
        case .clickhouse: clickHouse
        case .mssql: sqlServer
        case .oracle: oracle
        case .cassandra, .scylladb: cassandra
        case .teradata: teradata
        case .sapHana: sapHana
        case .dameng: dameng
        case .spanner: spanner
        case .bigQuery: bigQuery
        case .snowflake: snowflake
        case .trino, .presto: trino
        default: []
        }
    }

    static func expressions(for databaseType: DatabaseType, columnType: ColumnType?) -> [CellExpression] {
        guard let columnType, let kind = CellExpressionKind(columnType: columnType) else { return [] }
        return expressions(for: databaseType).filter { $0.kinds.contains(kind) }
    }

    static func expression(typed text: String, databaseType: DatabaseType, columnType: ColumnType?) -> CellExpression? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return expressions(for: databaseType, columnType: columnType).first { $0.matches(typed: trimmed) }
    }

    static func isCanonical(_ sql: String, for databaseType: DatabaseType) -> Bool {
        expressions(for: databaseType).contains { $0.sql == sql }
    }

    /// Whether `UPDATE ... SET c = DEFAULT` parses. Where it does not, a new row still takes Default, because its
    /// INSERT leaves the column out.
    static func updateTakesDefault(_ databaseType: DatabaseType) -> Bool {
        switch databaseType {
        case .sqlite, .libsql, .turso, .cloudflareD1, .clickhouse, .databend, .snowflake, .trino, .presto,
             .cassandra, .scylladb:
            false
        default:
            true
        }
    }

    private static let moment: Set<CellExpressionKind> = [.timestamp, .datetime]

    private static let postgreSQL: [CellExpression] = [
        CellExpression("now()", kinds: moment),
        CellExpression("CURRENT_TIMESTAMP", kinds: moment),
        CellExpression("LOCALTIMESTAMP", kinds: moment),
        CellExpression("CURRENT_DATE", kinds: [.date]),
        CellExpression("CURRENT_TIME", kinds: [.time]),
        CellExpression("LOCALTIME", kinds: [.time]),
    ]

    private static let cockroachDB: [CellExpression] = [
        CellExpression("now()", kinds: moment),
        CellExpression("current_timestamp()", kinds: moment, aliases: ["CURRENT_TIMESTAMP"]),
        CellExpression("localtimestamp", kinds: moment, aliases: ["LOCALTIMESTAMP()"]),
        CellExpression("current_date", kinds: [.date], aliases: ["CURRENT_DATE()"]),
        CellExpression("current_time", kinds: [.time], aliases: ["CURRENT_TIME()"]),
        CellExpression("localtime", kinds: [.time], aliases: ["LOCALTIME()"]),
    ]

    /// `NOW`, `CURRENT_TIMESTAMP` and `CURRENT_TIME` are leader-node only and fail in a statement on a table.
    private static let redshift: [CellExpression] = [
        CellExpression("GETDATE()", kinds: moment),
        CellExpression("SYSDATE", kinds: moment),
        CellExpression("CURRENT_DATE", kinds: [.date]),
    ]

    private static let mySQL: [CellExpression] = [
        CellExpression("NOW()", kinds: moment, aliases: ["LOCALTIMESTAMP", "LOCALTIMESTAMP()", "LOCALTIME", "LOCALTIME()"]),
        CellExpression("CURRENT_TIMESTAMP", kinds: moment, aliases: ["CURRENT_TIMESTAMP()"]),
        // Not an alias of NOW(): it reads the clock when evaluated and ignores SET TIMESTAMP.
        CellExpression("SYSDATE()", kinds: moment),
        CellExpression("UTC_TIMESTAMP()", kinds: moment),
        CellExpression("CURDATE()", kinds: [.date], aliases: ["CURRENT_DATE", "CURRENT_DATE()"]),
        CellExpression("UTC_DATE()", kinds: [.date]),
        CellExpression("CURTIME()", kinds: [.time], aliases: ["CURRENT_TIME", "CURRENT_TIME()"]),
        CellExpression("UTC_TIME()", kinds: [.time]),
    ]

    private static let databend: [CellExpression] = [
        CellExpression("NOW()", kinds: moment, aliases: ["CURRENT_TIMESTAMP()"]),
        CellExpression("TODAY()", kinds: [.date]),
    ]

    private static let sqlite: [CellExpression] = [
        CellExpression("CURRENT_TIMESTAMP", kinds: moment),
        CellExpression("datetime('now')", kinds: moment),
        CellExpression("datetime('now','localtime')", kinds: moment),
        CellExpression("CURRENT_DATE", kinds: [.date]),
        CellExpression("date('now')", kinds: [.date]),
        CellExpression("CURRENT_TIME", kinds: [.time]),
        CellExpression("time('now')", kinds: [.time]),
    ]

    private static let duckDB: [CellExpression] = [
        CellExpression("now()", kinds: moment, aliases: ["CURRENT_TIMESTAMP"]),
        CellExpression("current_localtimestamp()", kinds: moment, aliases: ["LOCALTIMESTAMP"]),
        CellExpression("current_date", kinds: [.date], aliases: ["CURRENT_DATE()"]),
        CellExpression("current_time", kinds: [.time]),
        CellExpression("localtime", kinds: [.time]),
    ]

    private static let clickHouse: [CellExpression] = [
        CellExpression("now()", kinds: moment, aliases: ["CURRENT_TIMESTAMP()", "UTC_TIMESTAMP()"]),
        CellExpression("today()", kinds: [.date], aliases: ["CURDATE()", "CURRENT_DATE()"]),
    ]

    /// Each type converts implicitly from `datetime`, so the two current-moment functions fill a date or a time too.
    private static let sqlServer: [CellExpression] = [
        CellExpression("SYSDATETIME()", kinds: [.timestamp, .datetime, .date, .time]),
        CellExpression("GETDATE()", kinds: [.timestamp, .datetime, .date, .time]),
        CellExpression("GETUTCDATE()", kinds: moment),
        CellExpression("SYSUTCDATETIME()", kinds: moment),
        CellExpression("CURRENT_TIMESTAMP", kinds: moment),
    ]

    /// An Oracle `DATE` holds a time of day, and each of these converts to `DATE` and `TIMESTAMP` on assignment.
    private static let oracle: [CellExpression] = [
        CellExpression("SYSTIMESTAMP", kinds: oracleMoment),
        CellExpression("CURRENT_TIMESTAMP", kinds: oracleMoment),
        CellExpression("LOCALTIMESTAMP", kinds: oracleMoment),
        CellExpression("SYSDATE", kinds: oracleMoment),
        CellExpression("CURRENT_DATE", kinds: oracleMoment),
    ]

    private static let oracleMoment: Set<CellExpressionKind> = [.timestamp, .datetime, .date]

    private static let cassandra: [CellExpression] = [
        CellExpression("currentTimestamp()", kinds: moment, aliases: ["toTimestamp(now())"]),
        CellExpression("currentDate()", kinds: [.date], aliases: ["toDate(now())"]),
        CellExpression("currentTime()", kinds: [.time]),
        CellExpression("now()", kinds: [.timeUUID]),
        CellExpression("currentTimeUUID()", kinds: [.timeUUID]),
    ]

    private static let teradata: [CellExpression] = [
        CellExpression("CURRENT_TIMESTAMP", kinds: moment),
        CellExpression("CURRENT_DATE", kinds: [.date]),
        CellExpression("CURRENT_TIME", kinds: [.time]),
    ]

    private static let sapHana: [CellExpression] = [
        CellExpression("CURRENT_TIMESTAMP", kinds: moment, aliases: ["NOW()"]),
        CellExpression("CURRENT_DATE", kinds: [.date]),
        CellExpression("CURRENT_TIME", kinds: [.time]),
    ]

    private static let dameng: [CellExpression] = [
        CellExpression("CURRENT_TIMESTAMP", kinds: moment),
        CellExpression("SYSDATE", kinds: moment),
        CellExpression("CURRENT_DATE", kinds: [.date]),
        CellExpression("CURRENT_TIME", kinds: [.time]),
    ]

    /// Without parentheses, the one spelling both the GoogleSQL and the PostgreSQL dialect parse.
    private static let spanner: [CellExpression] = [
        CellExpression("CURRENT_TIMESTAMP", kinds: moment),
        CellExpression("CURRENT_DATE", kinds: [.date]),
    ]

    private static let bigQuery: [CellExpression] = [
        CellExpression("CURRENT_TIMESTAMP()", kinds: [.timestamp], aliases: ["CURRENT_TIMESTAMP"]),
        CellExpression("CURRENT_DATETIME()", kinds: [.datetime], aliases: ["CURRENT_DATETIME"]),
        CellExpression("CURRENT_DATE()", kinds: [.date], aliases: ["CURRENT_DATE"]),
        CellExpression("CURRENT_TIME()", kinds: [.time], aliases: ["CURRENT_TIME"]),
    ]

    private static let snowflake: [CellExpression] = [
        CellExpression(
            "CURRENT_TIMESTAMP()", kinds: moment,
            aliases: ["CURRENT_TIMESTAMP", "LOCALTIMESTAMP", "LOCALTIMESTAMP()"]
        ),
        CellExpression("CURRENT_DATE()", kinds: [.date], aliases: ["CURRENT_DATE"]),
        CellExpression("CURRENT_TIME()", kinds: [.time], aliases: ["CURRENT_TIME", "LOCALTIME", "LOCALTIME()"]),
    ]

    private static let trino: [CellExpression] = [
        CellExpression("current_timestamp", kinds: moment, aliases: ["LOCALTIMESTAMP"]),
        CellExpression("now()", kinds: moment),
        CellExpression("current_date", kinds: [.date]),
        CellExpression("current_time", kinds: [.time], aliases: ["LOCALTIME"]),
    ]
}
