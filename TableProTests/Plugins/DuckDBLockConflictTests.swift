//
//  DuckDBLockConflictTests.swift
//  TableProTests
//
//  Tests for DuckDBLockConflict (compiled via project.yml from DuckDBDriverPlugin).
//
//  The two messages below are verbatim output from the shipped Libs/libduckdb_arm64.a, captured
//  by a C probe holding the file open in a second process. Do not tidy them: the parser exists to
//  read exactly this text, and a paraphrase would test nothing.
//

import Foundation
import Testing

@Suite("DuckDB lock conflict")
struct DuckDBLockConflictTests {
    private static let readWriteHolder = """
        IO Error: Could not set lock on file "/tmp/scratch/t.duckdb": Conflicting lock is held in \
        /tmp/scratch/lockprobe (PID 64911) by user ngoquocdat. \
        See also https://duckdb.org/docs/stable/connect/concurrency
        """

    private static let readOnlyHolder = """
        IO Error: Could not set lock on file "/tmp/scratch/t.duckdb": Conflicting lock is held in \
        /tmp/scratch/lockprobe (PID 65167) by user ngoquocdat. However, you would be able to open \
        this database in read-only mode, e.g. by using the -readonly parameter in the CLI. \
        See also https://duckdb.org/docs/stable/connect/concurrency
        """

    @Test("A read-write holder's message yields the file, the holder, its process and its user")
    func parsesReadWriteHolder() throws {
        let conflict = try #require(DuckDBLockConflict.parse(Self.readWriteHolder))
        #expect(conflict.filePath == "/tmp/scratch/t.duckdb")
        #expect(conflict.holderExecutablePath == "/tmp/scratch/lockprobe")
        #expect(conflict.holderProcessId == 64_911)
        #expect(conflict.holderUser == "ngoquocdat")
        #expect(conflict.holderName == "lockprobe")
    }

    /// DuckDB appends this sentence only when the process holding the file opened it read-only,
    /// which is the one case where retrying read-only actually gets in. Offering that recovery
    /// against a read-write holder would send the user to a setting that fails identically.
    @Test("Only a read-only holder's message offers the read-only route")
    func readOnlyHintTracksTheHolder() throws {
        let readWrite = try #require(DuckDBLockConflict.parse(Self.readWriteHolder))
        let readOnly = try #require(DuckDBLockConflict.parse(Self.readOnlyHolder))
        #expect(readWrite.readOnlyWouldSucceed == false)
        #expect(readOnly.readOnlyWouldSucceed == true)
        #expect(readOnly.holderProcessId == 65_167)
    }

    /// Measured alongside the others, and worth its own case because it also mentions read-only
    /// mode. Classifying it as a lock conflict would tell the user another app has a file that
    /// does not exist.
    @Test("A missing read-only database is not a lock conflict")
    func missingDatabaseIsNotALockConflict() {
        let message = """
            IO Error: Cannot open database "/tmp/scratch/nope.duckdb" in read-only mode: \
            database does not exist
            """
        #expect(DuckDBLockConflict.parse(message) == nil)
    }

    @Test("An unrelated DuckDB error is not a lock conflict")
    func unrelatedErrorIsNotALockConflict() {
        #expect(DuckDBLockConflict.parse("Catalog Error: Table with name t does not exist!") == nil)
        #expect(DuckDBLockConflict.parse("") == nil)
    }

    /// Everything past the anchor is optional so a reworded DuckDB release still classifies. The
    /// message then says another process has the file without naming it, which is worse than the
    /// full sentence and far better than surfacing the raw driver text.
    @Test("A reworded message still classifies, with the parts it can no longer find left empty")
    func degradesWhenTheWordingChanges() throws {
        let conflict = try #require(
            DuckDBLockConflict.parse("IO Error: Could not set lock on file \"/tmp/a.duckdb\": busy")
        )
        #expect(conflict.filePath == "/tmp/a.duckdb")
        #expect(conflict.holderExecutablePath == nil)
        #expect(conflict.holderProcessId == nil)
        #expect(conflict.holderName == nil)
    }

    @Test("The message names the holder and the file, and drops DuckDB's documentation URL")
    func describesTheHolderNotTheDriver() throws {
        let conflict = try #require(DuckDBLockConflict.parse(Self.readWriteHolder))
        #expect(conflict.localizedDescription.contains("lockprobe"))
        #expect(conflict.localizedDescription.contains("t.duckdb"))
        #expect(conflict.localizedDescription.contains("duckdb.org") == false)
    }

    @Test("Read-only is suggested only when DuckDB said it would work")
    func recoverySuggestionFollowsTheHint() throws {
        let readWrite = try #require(DuckDBLockConflict.parse(Self.readWriteHolder))
        let readOnly = try #require(DuckDBLockConflict.parse(Self.readOnlyHolder))
        #expect(readWrite.recoverySuggestion?.contains("Read-Only") == false)
        #expect(readOnly.recoverySuggestion?.contains("Read-Only") == true)
    }
}
