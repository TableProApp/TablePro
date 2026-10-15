import Foundation

/// The `sql_mode`, and for an event the `time_zone`, the server recorded when a routine, trigger or event was created
/// and applies whenever it runs, as the statements a script writes around the object's `CREATE`.
///
/// mysqldump's form (`switch_sql_mode`, `switch_time_zone` and their restores in `client/mysqldump.cc`): the object
/// saves the script's values in variables of its own, never the dump-wide `@OLD_SQL_MODE`, and the closing puts them
/// back in reverse order. No statement carries a terminator.
public struct MySQLCreationSettings: Equatable, Sendable {
    public let sqlMode: String
    public let timeZone: String?

    /// Nil when a value would close the version comment it is written in.
    public init?(sqlMode: String, timeZone: String? = nil) {
        guard !sqlMode.contains("*/"), timeZone?.contains("*/") != true else { return nil }
        let portableMode = Self.portableMode(sqlMode)
        self.sqlMode = portableMode
        self.timeZone = timeZone
    }

    /// MariaDB records `NO_AUTO_CREATE_USER` on every routine and trigger its default mode creates, and MySQL 8
    /// refuses the name with 1231, so a dump would stop at its first routine there. The mode only decides whether
    /// `GRANT` may create an account, and mysqldump 5.7 drops it the same way (`remove_sql_mode`).
    static func portableMode(_ mode: String) -> String {
        mode.split(separator: ",", omittingEmptySubsequences: false)
            .filter { $0 != "NO_AUTO_CREATE_USER" }
            .joined(separator: ",")
    }

    public var opening: [String] {
        var statements = [
            "/*!50003 SET @saved_sql_mode = @@sql_mode */",
            "/*!50003 SET sql_mode = '\(mysqlEscapeStringLiteral(sqlMode))' */",
        ]
        if let timeZone {
            statements.append("/*!50003 SET @saved_time_zone = @@time_zone */")
            statements.append("/*!50003 SET time_zone = '\(mysqlEscapeStringLiteral(timeZone))' */")
        }
        return statements
    }

    public var closing: [String] {
        var statements: [String] = []
        if timeZone != nil {
            statements.append("/*!50003 SET time_zone = @saved_time_zone */")
        }
        statements.append("/*!50003 SET sql_mode = @saved_sql_mode */")
        return statements
    }
}
