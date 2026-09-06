//
//  NativeDumpDestinationTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Native dump destinations")
struct NativeDumpDestinationTests {
    private let directory = URL(fileURLWithPath: "/tmp/backups")

    @Test("A file name carries the database, the timestamp and the engine's extension")
    func nameShape() {
        #expect(
            NativeDumpDestination.name(database: "sales", timestamp: "2026-09-06-142530", fileExtension: "dump")
                == "sales-2026-09-06-142530.dump"
        )
    }

    /// The Parquet format writes a folder, so the last path component carries no extension.
    @Test("A directory destination has no extension")
    func directoryName() {
        #expect(
            NativeDumpDestination.name(database: "sales", timestamp: "2026-09-06-142530", fileExtension: "")
                == "sales-2026-09-06-142530"
        )
    }

    /// `/` and `:` are both legal in a MySQL database name and neither survives a path component.
    @Test("A database name that is not a file name is sanitized")
    func sanitizing() {
        #expect(NativeDumpDestination.sanitized("a/b") == "a_b")
        #expect(NativeDumpDestination.sanitized("a:b") == "a_b")
        #expect(NativeDumpDestination.sanitized("plain-name_1") == "plain-name_1")
        #expect(NativeDumpDestination.sanitized("") == "database")
        #expect(NativeDumpDestination.sanitized("///") == "___")
    }

    @Test("Every database in one run gets its own file")
    func planIsOnePerDatabase() {
        let plan = NativeDumpDestination.plan(
            databases: ["sales", "billing", "analytics"],
            in: directory,
            timestamp: "2026-09-06-142530",
            fileExtension: "dump"
        )
        #expect(plan.map(\.database) == ["sales", "billing", "analytics"])
        #expect(plan.map { $0.url.lastPathComponent } == [
            "sales-2026-09-06-142530.dump",
            "billing-2026-09-06-142530.dump",
            "analytics-2026-09-06-142530.dump"
        ])
    }

    /// Two databases that differ only by a character a path cannot hold sanitize onto one name.
    /// Left alone, the run reports three backups written and two files exist.
    @Test("Names that sanitize onto each other are disambiguated instead of overwriting")
    func planAvoidsCollisions() {
        let plan = NativeDumpDestination.plan(
            databases: ["a/b", "a:b", "a b"],
            in: directory,
            timestamp: "t",
            fileExtension: "sql"
        )
        let names = plan.map { $0.url.lastPathComponent }
        #expect(Set(names).count == 3, "collided onto: \(names)")
        #expect(names[0] == "a_b-t.sql")
        #expect(names[1] == "a_b-t-2.sql")
    }

    @Test("A collision on a directory destination stays extensionless")
    func planAvoidsCollisionsWithoutExtension() {
        let plan = NativeDumpDestination.plan(
            databases: ["a/b", "a:b"],
            in: directory,
            timestamp: "t",
            fileExtension: ""
        )
        #expect(plan.map { $0.url.lastPathComponent } == ["a_b-t", "a_b-t-2"])
    }

    /// Measured on the vendored libduckdb: attaching a file that already holds a backup and copying
    /// into it fails with `Sequence with name "s1" already exists`, and `EXPORT DATABASE` merges
    /// into a folder that already holds one.
    @Test("Preparing a destination clears whatever is already there")
    func prepareClearsTheTarget() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("sales.duckdb")
        try NativeDumpDestination.prepare(file, producesDirectory: false)
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try Data("stale".utf8).write(to: file)
        try NativeDumpDestination.prepare(file, producesDirectory: false)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Preparing a folder destination leaves an empty folder behind")
    func prepareCreatesAnEmptyFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("sales")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: folder.appendingPathComponent("orphan.parquet"))

        try NativeDumpDestination.prepare(folder, producesDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(contents.isEmpty, "left behind: \(contents)")
    }
}
