import Foundation
import Testing

@testable import TableProMySQLCore

struct MySQLCreationSettingsTests {
    @Test("A routine or trigger switches the mode through its own variable and puts it back")
    func modeOnly() throws {
        let settings = try #require(MySQLCreationSettings(sqlMode: "STRICT_TRANS_TABLES,NO_ZERO_DATE"))
        #expect(settings.opening == [
            "/*!50003 SET @saved_sql_mode = @@sql_mode */",
            "/*!50003 SET sql_mode = 'STRICT_TRANS_TABLES,NO_ZERO_DATE' */",
        ])
        #expect(settings.closing == ["/*!50003 SET sql_mode = @saved_sql_mode */"])
    }

    @Test("An event also switches the time zone, and the closing undoes both in reverse order")
    func modeAndTimeZone() throws {
        let settings = try #require(MySQLCreationSettings(sqlMode: "", timeZone: "SYSTEM"))
        #expect(settings.opening == [
            "/*!50003 SET @saved_sql_mode = @@sql_mode */",
            "/*!50003 SET sql_mode = '' */",
            "/*!50003 SET @saved_time_zone = @@time_zone */",
            "/*!50003 SET time_zone = 'SYSTEM' */",
        ])
        #expect(settings.closing == [
            "/*!50003 SET time_zone = @saved_time_zone */",
            "/*!50003 SET sql_mode = @saved_sql_mode */",
        ])
    }

    @Test("No statement carries a terminator, and none touches the dump-wide @OLD_SQL_MODE")
    func leavesTheDumpAlone() throws {
        let settings = try #require(MySQLCreationSettings(sqlMode: "ANSI_QUOTES", timeZone: "+02:00"))
        for statement in settings.opening + settings.closing {
            #expect(!statement.hasSuffix(";"), "\(statement)")
            #expect(!statement.contains("@OLD_SQL_MODE"), "\(statement)")
        }
    }

    @Test("A quote in a value is escaped")
    func quotesAreEscaped() throws {
        let settings = try #require(MySQLCreationSettings(sqlMode: "A'B", timeZone: "C'D"))
        #expect(settings.opening[1] == "/*!50003 SET sql_mode = 'A''B' */")
        #expect(settings.opening[3] == "/*!50003 SET time_zone = 'C''D' */")
    }

    /// MariaDB's default mode puts it on every routine and trigger, and MySQL 8 refuses the name with 1231.
    @Test("NO_AUTO_CREATE_USER is dropped wherever it stands in the recorded mode", arguments: [
        ("STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION",
         "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"),
        ("NO_AUTO_CREATE_USER,STRICT_TRANS_TABLES", "STRICT_TRANS_TABLES"),
        ("STRICT_TRANS_TABLES,NO_AUTO_CREATE_USER", "STRICT_TRANS_TABLES"),
        ("NO_AUTO_CREATE_USER", ""),
        ("STRICT_TRANS_TABLES", "STRICT_TRANS_TABLES"),
        ("", ""),
    ])
    func noAutoCreateUserIsDropped(_ recorded: String, _ written: String) throws {
        let settings = try #require(MySQLCreationSettings(sqlMode: recorded))
        #expect(settings.sqlMode == written)
        #expect(settings.opening[1] == "/*!50003 SET sql_mode = '\(written)' */")
    }

    @Test("A value that would close the version comment gives no settings")
    func commentCloserIsRefused() {
        #expect(MySQLCreationSettings(sqlMode: "x */ DROP TABLE t; /*") == nil)
        #expect(MySQLCreationSettings(sqlMode: "", timeZone: "*/") == nil)
    }
}
