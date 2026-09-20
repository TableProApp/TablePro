import Foundation

/// The one owner of how the app names an Oracle data dictionary object, performance view or system package.
///
/// Oracle resolves an unqualified name to an object in the session's current schema before the public synonym that
/// points at the real `SYS` object, so a user who owns the current schema, or a schema the reader has switched into
/// with `ALTER SESSION SET CURRENT_SCHEMA`, can plant a table, view or package of the same name and have the app read
/// or run it instead. Owner-qualifying every dictionary name closes that at SQL level, where the first component of a
/// qualified name is a schema before it is any object: a table or package named `SYS` in the current schema does not
/// capture `SYS.ALL_TABLES` (measured on Oracle 23ai and on Dameng DM8).
///
/// This holds only for names resolved at SQL level. A `SYS.`-qualified name inside a PL/SQL block resolves through
/// PL/SQL, which reaches a package named `SYS` in the current schema first, so app-issued PL/SQL reaches a system
/// package through a SQL-level `CALL` instead (see ``OracleServerOutput`` and the server-side export block).
public enum OracleDictionary {
    public static let owner = "SYS"

    /// A data dictionary view or table (`ALL_*`, `DBA_*`, `USER_*`), owner-qualified.
    public static func view(_ name: String) -> String {
        "\(owner).\(name)"
    }

    /// A dynamic performance view, owner-qualified to the real `V_$`/`GV_$` view.
    ///
    /// `V$X` and `GV$X` are public synonyms, so a current-schema object shadows them, and `SYS.V$X` does not exist:
    /// only `SYS.V_$X` resolves (measured on 23ai, where `SYS.V$VERSION` raised ORA-00942 and `SYS.V_$VERSION` returned
    /// the banner).
    public static func performanceView(_ name: String) -> String {
        if name.hasPrefix("GV$") {
            return "\(owner).GV_$\(name.dropFirst(3))"
        }
        if name.hasPrefix("V$") {
            return "\(owner).V_$\(name.dropFirst(2))"
        }
        return view(name)
    }

    /// A system package addressed at SQL level, owner-qualified. Use it only where the reference is resolved by SQL, a
    /// `CALL` statement, so the qualification holds; a PL/SQL block reaches a shadow package first whatever the prefix.
    public static func package(_ name: String) -> String {
        "\(owner).\(name)"
    }

    public static let allTables = view("ALL_TABLES")
    public static let allViews = view("ALL_VIEWS")
    public static let allTabColumns = view("ALL_TAB_COLUMNS")
    public static let allConstraints = view("ALL_CONSTRAINTS")
    public static let allConsColumns = view("ALL_CONS_COLUMNS")
    public static let allIndexes = view("ALL_INDEXES")
    public static let allIndColumns = view("ALL_IND_COLUMNS")
    public static let allUsers = view("ALL_USERS")
    public static let allPartTables = view("ALL_PART_TABLES")
    public static let allTabPartitions = view("ALL_TAB_PARTITIONS")
    public static let allTabSubpartitions = view("ALL_TAB_SUBPARTITIONS")
    public static let allTabComments = view("ALL_TAB_COMMENTS")
    public static let allColComments = view("ALL_COL_COMMENTS")
    public static let allErrors = view("ALL_ERRORS")
    public static let allObjects = view("ALL_OBJECTS")
    public static let allSource = view("ALL_SOURCE")
    public static let allTriggers = view("ALL_TRIGGERS")
    public static let dual = view("DUAL")
    public static let dbaSegments = view("DBA_SEGMENTS")
    public static let userSegments = view("USER_SEGMENTS")
    public static let versionView = performanceView("V$VERSION")
}
