import Foundation
import TableProSQLGrammar

public enum TrinoStatementSplitter {
    // The app's gates count statements with this scanner and grammar, so the driver never sends a piece they did not see.
    public static func split(_ sql: String) -> [String] {
        SQLStatementScanner.allStatements(in: sql, grammar: .ansi)
    }

    // A host-split text is the one statement the host approved: it goes whole, and the server refuses a second one in it.
    public static func statements(in sql: String, hostSplit: Bool) -> [String] {
        guard !hostSplit, sql.contains(";") else { return [sql] }
        return split(sql)
    }
}
