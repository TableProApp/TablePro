import Foundation

/// The words a T-SQL statement can begin with.
///
/// A batch may open with a bare procedure name, `sp_help 't'` or `dbo.usp_Report @from`, and the server runs it as an
/// `EXECUTE`, but only while it is the batch's first statement. So a batch whose first word is none of these is a
/// procedure call, and nothing may be put in front of it: measured, a declaration ahead of `sp_help` fails with Msg 102.
/// A word missing here only costs a batch the `sp_executesql` binding it would take anyway, never a failed run.
public enum MSSQLStatementKeywords {
    public static let leading: Set<String> = [
        "ADD", "ALTER", "BACKUP", "BEGIN", "BREAK", "BULK", "CHECKPOINT", "CLOSE", "COMMIT", "CONTINUE", "CREATE",
        "DBCC", "DEALLOCATE", "DECLARE", "DELETE", "DENY", "DISABLE", "DROP", "ENABLE", "END", "EXEC", "EXECUTE",
        "FETCH", "GET", "GOTO", "GRANT", "IF", "INSERT", "KILL", "MERGE", "MOVE", "OPEN", "PRINT", "RAISERROR",
        "READTEXT", "RECEIVE", "RECONFIGURE", "RESTORE", "RETURN", "REVERT", "REVOKE", "ROLLBACK", "SAVE", "SELECT",
        "SEND", "SET", "SETUSER", "SHUTDOWN", "THROW", "TRUNCATE", "UPDATE", "UPDATETEXT", "USE", "WAITFOR", "WHILE",
        "WITH", "WRITETEXT",
    ]
}
