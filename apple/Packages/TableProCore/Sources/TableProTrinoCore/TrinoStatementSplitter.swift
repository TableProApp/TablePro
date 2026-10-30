import Foundation
import TableProSQLGrammar

public enum TrinoStatementSplitter {
    // The app's gates count statements with this scanner and grammar, so the driver never sends a piece they did not see.
    public static func split(_ sql: String) -> [String] {
        SQLStatementScanner.allStatements(in: sql, grammar: .ansi)
    }
}
