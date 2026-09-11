//
//  SQLExportEncodingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SQL export encoding declaration")
struct SQLExportEncodingTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("A MySQL dump declares utf8mb4 the way mysqldump does, and puts the session back")
    func mysqlDeclaresUTF8MB4() {
        for typeId in ["MySQL", "MariaDB", "TiDB"] {
            let declaration = SQLExportEncodingDeclaration.forDatabaseType(typeId)
            #expect(declaration.prologue.contains("/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;"))
            #expect(declaration.prologue.contains("/*!40101 SET NAMES utf8 */;"))
            #expect(declaration.prologue.contains("/*!50503 SET NAMES utf8mb4 */;"))
            #expect(declaration.epilogue.contains("/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;"))
            #expect(declaration.epilogue.contains("/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;"))
            #expect(declaration.epilogue.contains("/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;"))
        }
    }

    @Test("A PostgreSQL dump declares UTF8 the way pg_dump does, on every engine that accepts the statement")
    func postgresDeclaresUTF8() {
        for typeId in ["PostgreSQL", "Greenplum", "AlloyDB", "Citus", "CockroachDB", "PGlite"] {
            let declaration = SQLExportEncodingDeclaration.forDatabaseType(typeId)
            #expect(declaration.prologue == "SET client_encoding = 'UTF8';\n\n", "\(typeId)")
            #expect(declaration.epilogue.isEmpty, "\(typeId)")
        }
    }

    @Test("Redshift gets no declaration, because it does not document client_encoding as settable")
    func redshiftDeclaresNothing() {
        #expect(SQLExportEncodingDeclaration.forDatabaseType("Redshift") == .empty)
    }

    @Test("Other engines write no declaration")
    func otherEnginesDeclareNothing() {
        for typeId in ["SQLite", "DuckDB", "Oracle", "MSSQL", "SomeFuturePlugin"] {
            #expect(SQLExportEncodingDeclaration.forDatabaseType(typeId) == .empty, "\(typeId)")
        }
    }

    @Test("A PostgreSQL dump opens with the declaration and ends with the last statement")
    func postgresDumpIsPrefixed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let declaration = SQLExportEncodingDeclaration.forDatabaseType("PostgreSQL")

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(
            destination: destination, splitSizeMegabytes: 0, encodingDeclaration: declaration
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
        let declaration = SQLExportEncodingDeclaration.forDatabaseType("MySQL")

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(
            destination: destination, splitSizeMegabytes: 0, encodingDeclaration: declaration
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
        let declaration = SQLExportEncodingDeclaration.forDatabaseType(databaseTypeId)
        #expect(declaration != .empty)

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(
            destination: destination, splitSizeMegabytes: 1, encodingDeclaration: declaration
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
        let declaration = SQLExportEncodingDeclaration.forDatabaseType("MySQL")
        let cap = 1_024 * 1_024

        let destination = directory.appendingPathComponent("dump.sql")
        let writer = try SQLExportFileWriter(
            destination: destination, splitSizeMegabytes: 1, encodingDeclaration: declaration
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
            encodingDeclaration: .forDatabaseType("MySQL")
        )
        try writer.write(String(repeating: "y", count: 2 * 1_024 * 1_024) + ";\n")
        let parts = try writer.commit()

        #expect(parts.count == 1)
        #expect(!writer.didSplit)
    }
}
