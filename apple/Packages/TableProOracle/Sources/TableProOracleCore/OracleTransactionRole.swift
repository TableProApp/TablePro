import Foundation

/// What a statement does to the session's transaction, read from its first words.
enum OracleTransactionRole: Equatable, Sendable {
    /// `SELECT` or `WITH`. A query writes nothing, so it never needs a commit, and a commit sent with a
    /// `SELECT ... FOR UPDATE` ends the transaction its cursor belongs to: measured on Oracle 23ai, fetching past the
    /// first round trip then fails with ORA-01002.
    case query

    /// `SET TRANSACTION`, `SAVEPOINT` or `LOCK TABLE`. Each one only means something inside a transaction, and Oracle
    /// opens one for it (measured: `DBMS_TRANSACTION.LOCAL_TRANSACTION_ID` is set after a `SAVEPOINT` alone), so it
    /// opens one here rather than being committed away the moment it runs.
    case opensTransaction

    /// `COMMIT`, or a `ROLLBACK` that is not to a savepoint.
    case endsTransaction

    // Oracle commits before and after DDL (SQL Reference, COMMIT). ALTER SESSION and ALTER SYSTEM are
    // session and system control, which commit nothing, and the schema switch sends ALTER SESSION.
    case dataDefinition

    /// An anonymous block (`BEGIN` or `DECLARE`, after any `<<label>>`) or a `CALL`. It can run DDL through
    /// `EXECUTE IMMEDIATE`, or commit or roll back, so whether a transaction survived it is the server's answer.
    case procedural

    /// Everything else: DML, `ROLLBACK TO`, session and system control, and the `FORCE` forms of `COMMIT` and
    /// `ROLLBACK`, which settle an in-doubt distributed transaction rather than the session's own.
    case other

    /// How much of a statement is read for its first words. A dump can hold a statement millions of characters long,
    /// and every statement the driver runs is read here.
    private static let headerScanLimit = 4_096

    init(of sql: String) {
        var reader = HeaderReader(String(String.UnicodeScalarView(sql.unicodeScalars.prefix(Self.headerScanLimit))))
        reader.skipLabels()
        switch reader.nextWord() {
        case "SELECT", "WITH":
            self = .query
        case "BEGIN", "DECLARE", "CALL":
            self = .procedural
        case "SAVEPOINT":
            self = .opensTransaction
        case "SET":
            self = reader.nextWord() == "TRANSACTION" ? .opensTransaction : .other
        case "LOCK":
            self = reader.nextWord() == "TABLE" ? .opensTransaction : .other
        case "COMMIT":
            self = Self.skippingWork(&reader) == "FORCE" ? .other : .endsTransaction
        case "ROLLBACK":
            let word = Self.skippingWork(&reader)
            self = word == "TO" || word == "FORCE" ? .other : .endsTransaction
        case "CREATE", "DROP", "TRUNCATE", "RENAME", "GRANT", "REVOKE", "COMMENT", "AUDIT", "NOAUDIT", "ANALYZE",
             "PURGE", "FLASHBACK":
            self = .dataDefinition
        case "ALTER":
            let word = reader.nextWord()
            self = word == "SESSION" || word == "SYSTEM" ? .other : .dataDefinition
        case "ASSOCIATE", "DISASSOCIATE":
            self = reader.nextWord() == "STATISTICS" ? .dataDefinition : .other
        default:
            self = .other
        }
    }

    // A refused COMMIT, ROLLBACK, DDL statement or block may still have ended the transaction: only the server knows.
    var mayEndTransactionWhenRefused: Bool {
        self == .endsTransaction || self == .dataDefinition || self == .procedural
    }

    private static func skippingWork(_ reader: inout HeaderReader) -> String? {
        let word = reader.nextWord()
        guard word == "WORK" else { return word }
        return reader.nextWord()
    }
}
