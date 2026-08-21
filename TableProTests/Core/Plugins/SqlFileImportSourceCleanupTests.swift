//
//  SqlFileImportSourceCleanupTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// A `.gz` the source expanded itself is the source's to delete, whoever owns the file the caller
/// handed over. Gating both on one flag leaked the whole expanded dump on every retry, because a
/// retry arrives with no caller-supplied file and therefore with the flag off.
/// Serialized because it watches the shared temporary directory for the file the source expands
/// into, and a `.sql` file another test wrote in the same window would be mistaken for it.
@Suite("SQL file import source cleanup", .serialized)
struct SqlFileImportSourceCleanupTests {
    private func writeGzip(_ sql: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sql-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plain = directory.appendingPathComponent("dump.sql")
        try sql.write(to: plain, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = [plain.path]
        try process.run()
        process.waitUntilExit()

        return directory.appendingPathComponent("dump.sql.gz")
    }

    /// `FileDecompressor` writes to `temporaryDirectory/<UUID>.sql`, so the file cannot be found by
    /// name. The test watches which `.sql` files appear while it runs instead.
    private func temporarySQLFiles() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return Set(contents.filter { $0.pathExtension == "sql" }.map(\.lastPathComponent))
    }

    /// The retry shape: `ImportDialog` clears `tempPreviewURL` on the first attempt, so the second
    /// attempt constructs the source with no decompressed file and `ownsDecompressedFile: false`.
    @Test("A retry cleans up the file it decompressed for itself")
    func retryCleansUpItsOwnDecompressedFile() async throws {
        let archive = try writeGzip("SELECT 1;\n")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let before = temporarySQLFiles()

        let source = SqlFileImportSource(
            url: archive,
            encoding: .utf8,
            dialect: .generic,
            decompressedURL: nil,
            ownsDecompressedFile: false
        )
        _ = try await source.statements()

        let decompressed = temporarySQLFiles().subtracting(before)
        #expect(!decompressed.isEmpty, "the source did not decompress anything, so nothing is proven")

        source.cleanup()

        let leaked = temporarySQLFiles().intersection(decompressed)
        #expect(leaked.isEmpty, "cleanup left the decompressed dump behind: \(leaked)")
    }

    /// The first-attempt shape, where the dialog hands over the file it decompressed for the
    /// preview and says the source now owns it.
    @Test("A caller-supplied decompressed file is removed when the source owns it")
    func callerSuppliedFileIsRemovedWhenOwned() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sql-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = directory.appendingPathComponent("dump.sql.gz")
        try Data().write(to: archive)
        let expanded = directory.appendingPathComponent("expanded.sql")
        try "SELECT 1;\n".write(to: expanded, atomically: true, encoding: .utf8)

        let source = SqlFileImportSource(
            url: archive,
            encoding: .utf8,
            dialect: .generic,
            decompressedURL: expanded,
            ownsDecompressedFile: true
        )
        source.cleanup()

        #expect(FileManager.default.fileExists(atPath: expanded.path) == false)
    }

    /// The dialog still needs its own preview copy afterwards when it kept ownership.
    @Test("A caller-supplied decompressed file is left alone when the source does not own it")
    func callerSuppliedFileSurvivesWhenNotOwned() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sql-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = directory.appendingPathComponent("dump.sql.gz")
        try Data().write(to: archive)
        let expanded = directory.appendingPathComponent("expanded.sql")
        try "SELECT 1;\n".write(to: expanded, atomically: true, encoding: .utf8)

        let source = SqlFileImportSource(
            url: archive,
            encoding: .utf8,
            dialect: .generic,
            decompressedURL: expanded,
            ownsDecompressedFile: false
        )
        source.cleanup()

        #expect(FileManager.default.fileExists(atPath: expanded.path))
    }
}
