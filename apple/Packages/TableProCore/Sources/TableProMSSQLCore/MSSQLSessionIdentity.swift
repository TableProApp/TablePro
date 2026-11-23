import Foundation

/// The schema a new session lands in and the server's banner, asked in one statement: every
/// connection of a session asks both before any work, so one round trip each matters.
public struct MSSQLSessionIdentity: Equatable, Sendable {
    public static let query = "SELECT SCHEMA_NAME(), @@VERSION"

    /// Nil when the server named none, so the caller keeps the schema it had.
    public let schema: String?
    public let version: String?

    /// The texts of the answer's first row, in the order `query` asks for them.
    public init(columns: [String?]) {
        let schema = columns.first ?? nil
        self.schema = schema?.isEmpty == false ? schema : nil
        self.version = columns.count > 1 ? columns[1] : nil
    }
}
