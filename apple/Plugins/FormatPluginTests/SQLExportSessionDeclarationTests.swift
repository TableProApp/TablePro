//
//  SQLExportSessionDeclarationTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

struct SQLExportSessionDeclarationTests {
    private static let mysqlFamily = ["MySQL", "MariaDB", "TiDB", "OceanBase"]

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("A MySQL dump declares utf8mb4 the way mysqldump does, and puts the session back")
    func mysqlDeclaresUTF8MB4() {
        for typeId in Self.mysqlFamily {
            let declaration = SQLExportSessionDeclaration.forDatabaseType(typeId)
            #expect(declaration.prologue.contains("/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;"))
            #expect(declaration.prologue.contains("/*!40101 SET NAMES utf8 */;"))
            #expect(declaration.prologue.contains("/*!50503 SET NAMES utf8mb4 */;"))
            #expect(declaration.epilogue.contains("/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;"))
            #expect(declaration.epilogue.contains("/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;"))
            #expect(declaration.epilogue.contains("/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;"))
        }
    }

    /// #3414: without the mode line a MySQL 8 server refuses the dump's zero dates with 1292 and renumbers an
    /// AUTO_INCREMENT value of 0.
    @Test("A MySQL-family dump pins mysqldump's SQL_MODE and turns foreign key checks off, and restores both")
    func mysqlFamilyPinsTheSQLModeAndForeignKeyChecks() {
        for typeId in Self.mysqlFamily {
            let declaration = SQLExportSessionDeclaration.forDatabaseType(typeId)
            #expect(declaration.prologue.contains(
                "/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;"), "\(typeId)")
            #expect(declaration.prologue.contains(
                "/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;"), "\(typeId)")
            #expect(declaration.epilogue.contains("/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;"), "\(typeId)")
            #expect(declaration.epilogue.contains(
                "/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;"), "\(typeId)")
        }
    }

    @Test("Without a read time zone the MySQL declaration is mysqldump's text minus the zone pair")
    func mysqlDeclarationWithoutTimeZone() {
        let declaration = SQLExportSessionDeclaration.forDatabaseType("MySQL")
        #expect(declaration.prologue == """
            /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
            /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
            /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
            /*!40101 SET NAMES utf8 */;
            /*!50503 SET NAMES utf8mb4 */;
            /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
            /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;


            """)
        #expect(declaration.epilogue == """

            /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
            /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
            /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
            /*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
            /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;

            """)
        #expect(!declaration.prologue.contains("TIME_ZONE"))
        #expect(!declaration.epilogue.contains("TIME_ZONE"))
    }

    @Test("The zone the rows were read in is declared before the mode and restored first")
    func mysqlDeclarationWithTimeZone() {
        for typeId in Self.mysqlFamily {
            let declaration = SQLExportSessionDeclaration.forDatabaseType(typeId, readTimeZone: "+00:00")
            #expect(declaration.prologue == """
                /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
                /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
                /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
                /*!40101 SET NAMES utf8 */;
                /*!50503 SET NAMES utf8mb4 */;
                /*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
                /*!40103 SET TIME_ZONE='+00:00' */;
                /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
                /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;


                """, "\(typeId)")
            #expect(declaration.epilogue == """

                /*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;
                /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
                /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
                /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
                /*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
                /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;

                """, "\(typeId)")
        }
    }

    @Test("A dump whose DDL was read under ANSI_QUOTES keeps it in the mode it pins, and restores the same way")
    func ansiQuotesJoinsTheDumpMode() {
        for typeId in Self.mysqlFamily {
            let declaration = SQLExportSessionDeclaration.forDatabaseType(typeId, readsWithANSIQuotes: true)
            let plain = SQLExportSessionDeclaration.forDatabaseType(typeId)
            #expect(declaration.prologue == plain.prologue.replacingOccurrences(
                of: "SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;",
                with: "SQL_MODE='NO_AUTO_VALUE_ON_ZERO,ANSI_QUOTES' */;"), "\(typeId)")
            #expect(declaration.prologue != plain.prologue, "\(typeId)")
            #expect(declaration.epilogue == plain.epilogue, "\(typeId)")
        }
        #expect(SQLExportSessionDeclaration.forDatabaseType("PostgreSQL", readsWithANSIQuotes: true)
            == SQLExportSessionDeclaration.forDatabaseType("PostgreSQL"))
        #expect(SQLExportSessionDeclaration.forDatabaseType("SQLite", readsWithANSIQuotes: true) == .empty)
    }

    @Test(
        "A plain zone spelling is declared as written",
        arguments: ["+00:00", "-05:30", "SYSTEM", "UTC", "Europe/Paris", "America/Argentina/Buenos_Aires", "Etc/GMT+5"]
    )
    func plainTimeZoneIsDeclared(zone: String) {
        let declaration = SQLExportSessionDeclaration.forDatabaseType("MySQL", readTimeZone: zone)
        #expect(declaration.prologue.contains("/*!40103 SET TIME_ZONE='\(zone)' */;"))
        #expect(declaration.epilogue.contains("/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;"))
    }

    /// The zone sits inside `/*! */` and a string literal, so a `*/` or a quote would end one of them early.
    @Test(
        "A zone that is not a plain spelling is dropped, and the dump declares none",
        arguments: [
            "+00:00' */; DROP TABLE t; /*", "*/", "it's", "Europe\\Paris", "UTC ", "", "Zürich",
            String(repeating: "A", count: 65),
        ]
    )
    func unusualTimeZoneIsDropped(zone: String) {
        let declaration = SQLExportSessionDeclaration.forDatabaseType("MySQL", readTimeZone: zone)
        #expect(declaration == .forDatabaseType("MySQL"))
        #expect(!declaration.prologue.contains("TIME_ZONE"))
        #expect(!declaration.epilogue.contains("TIME_ZONE"))
    }

    @Test("A PostgreSQL dump declares UTF8 the way pg_dump does, on every engine that accepts the statement")
    func postgresDeclaresUTF8() {
        for typeId in ["PostgreSQL", "Greenplum", "AlloyDB", "Citus", "CockroachDB", "PGlite"] {
            let declaration = SQLExportSessionDeclaration.forDatabaseType(typeId)
            #expect(declaration.prologue == "SET client_encoding = 'UTF8';\n\n", "\(typeId)")
            #expect(declaration.epilogue.isEmpty, "\(typeId)")
            #expect(SQLExportSessionDeclaration.forDatabaseType(typeId, readTimeZone: "+00:00") == declaration, "\(typeId)")
        }
    }

    @Test("Redshift gets no declaration, because it does not document client_encoding as settable")
    func redshiftDeclaresNothing() {
        #expect(SQLExportSessionDeclaration.forDatabaseType("Redshift") == .empty)
    }

    @Test("Other engines write no declaration, with or without a read time zone")
    func otherEnginesDeclareNothing() {
        for typeId in ["SQLite", "DuckDB", "Oracle", "MSSQL", "Databend", "SomeFuturePlugin"] {
            #expect(SQLExportSessionDeclaration.forDatabaseType(typeId) == .empty, "\(typeId)")
            #expect(SQLExportSessionDeclaration.forDatabaseType(typeId, readTimeZone: "+00:00") == .empty, "\(typeId)")
        }
    }

    @Test("A PostgreSQL dump opens with the declaration and ends with the last statement")
    func postgresDumpIsPrefixed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let declaration = SQLExportSessionDeclaration.forDatabaseType("PostgreSQL")

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(
            destination: destination, splitSizeMegabytes: 0, sessionDeclaration: declaration
        )
        try writer.write("INSERT INTO \"t\" VALUES ('メール');\n")
        try writer.commit()

        let dump = try String(contentsOf: destination, encoding: .utf8)
        #expect(dump == "SET client_encoding = 'UTF8';\n\nINSERT INTO \"t\" VALUES ('メール');\n")
    }

    @Test("An unsplit dump opens with the declaration and closes by restoring the session")
    func unsplitDumpIsWrapped() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let declaration = SQLExportSessionDeclaration.forDatabaseType("MySQL", readTimeZone: "+00:00")

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(
            destination: destination, splitSizeMegabytes: 0, sessionDeclaration: declaration
        )
        try writer.write("INSERT INTO `t` VALUES ('メール');\n")
        try writer.commit()

        let dump = try String(contentsOf: destination, encoding: .utf8)
        #expect(dump == declaration.prologue + "INSERT INTO `t` VALUES ('メール');\n" + declaration.epilogue)
    }

    @Test(
        "Every part of a split dump carries its own declaration, so each restores on its own",
        arguments: ["MySQL", "PostgreSQL"]
    )
    func everyPartIsWrapped(databaseTypeId: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let declaration = SQLExportSessionDeclaration.forDatabaseType(databaseTypeId, readTimeZone: "+00:00")
        #expect(declaration != .empty)

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(
            destination: destination, splitSizeMegabytes: 1, sessionDeclaration: declaration
        )
        let chunk = String(repeating: "x", count: 700 * 1_024)
        try writer.write("A\(chunk);\n")
        try writer.write("B\(chunk);\n")
        let parts = try writer.commit()

        #expect(parts.count == 2)
        for (index, part) in parts.enumerated() {
            let text = try String(contentsOf: part, encoding: .utf8)
            #expect(text.hasPrefix(declaration.prologue), "part \(index + 1)")
            #expect(text.hasSuffix(declaration.epilogue), "part \(index + 1)")
            #expect(text.contains(index == 0 ? "A" : "B"))
        }
    }

    @Test("No part grows past the cap once its closing declaration is added")
    func epilogueCountsTowardTheCap() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let declaration = SQLExportSessionDeclaration.forDatabaseType("MySQL", readTimeZone: "+00:00")
        let cap = 1_024 * 1_024

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(
            destination: destination, splitSizeMegabytes: 1, sessionDeclaration: declaration
        )
        let firstLength = cap - declaration.prologue.utf8.count - declaration.epilogue.utf8.count - 5
        try writer.write(String(repeating: "a", count: firstLength - 2) + ";\n")
        try writer.write("SELECT 1;\n")
        let parts = try writer.commit()

        #expect(parts.count == 2)
        for part in parts {
            let size = try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int ?? 0
            #expect(size <= cap, "\(part.lastPathComponent) is \(size) bytes")
        }
    }

    @Test("A statement larger than the cap still lands in a part of its own, not after an empty one")
    func oversizedStatementDoesNotLeaveAnEmptyPart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(
            destination: destination, splitSizeMegabytes: 1,
            sessionDeclaration: .forDatabaseType("MySQL")
        )
        try writer.write(String(repeating: "y", count: 2 * 1_024 * 1_024) + ";\n")
        let parts = try writer.commit()

        #expect(parts.count == 1)
        #expect(!writer.didSplit)
    }
    @Test("KingbaseES dumps declare PostgreSQL string and encoding semantics")
    func kingbaseSessionDeclaration() {
        #expect(SQLExportSessionDeclaration.forDatabaseType("KingbaseES")
            == SQLExportSessionDeclaration.forDatabaseType("PostgreSQL"))
        #expect(!SQLExportSessionDeclaration.forDatabaseType("KingbaseES").prologue.isEmpty)
    }

}
