import Foundation

/// A table-level CHECK constraint as the server reports it.
///
/// `expression` is whatever the catalog returns, which is a re-parsed normal form rather than the
/// text the author typed: PostgreSQL renders `a IN (1,2,3)` as `a = ANY (ARRAY[1, 2, 3])`, MySQL
/// and MariaDB backtick-quote every identifier, and MSSQL wraps each operand in parentheses. A
/// driver passes it through unchanged rather than trying to restore the original spelling.
///
/// `columns` is empty when the engine has no catalog for it. Only PostgreSQL (`pg_constraint.conkey`)
/// and MSSQL (`sys.sql_expression_dependencies`) can answer it; MySQL, MariaDB and SQLite cannot,
/// and deriving it from the expression would be a SQL parse, not a pattern match.
public struct PluginCheckConstraintInfo: Codable, Sendable {
    public let name: String
    public let expression: String
    public let columns: [String]
    public let isValidated: Bool

    public init(
        name: String,
        expression: String,
        columns: [String] = [],
        isValidated: Bool = true
    ) {
        self.name = name
        self.expression = expression
        self.columns = columns
        self.isValidated = isValidated
    }
}
