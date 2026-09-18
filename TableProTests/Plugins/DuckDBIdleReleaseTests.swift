//
//  DuckDBIdleReleaseTests.swift
//  TableProTests
//
//  Tests for DuckDBIdleRelease and DuckDBAccessMode (compiled via project.yml from
//  DuckDBDriverPlugin).
//

import Foundation
import Testing

@Suite("DuckDB idle release policy")
struct DuckDBIdleReleaseTests {
    /// Every one of these is a value the connection form or a hand-edited file can produce, and
    /// each has to mean "never" rather than some interval nobody chose. A malformed setting that
    /// released the file on a guessed schedule would drop the lock under a user who never asked.
    @Test("Anything that is not a positive number of minutes means never")
    func malformedValuesMeanNever() {
        for value in [nil, "", "   ", "0", "-1", "-30", "abc", "5 minutes", "1.5", "٣"] {
            #expect(DuckDBIdleRelease.minutes(fromFieldValue: value) == nil, "\(value ?? "nil")")
            #expect(DuckDBIdleRelease.interval(fromFieldValue: value) == nil, "\(value ?? "nil")")
        }
    }

    @Test("A positive number of minutes becomes that interval")
    func positiveValuesParse() {
        #expect(DuckDBIdleRelease.minutes(fromFieldValue: "1") == 1)
        #expect(DuckDBIdleRelease.minutes(fromFieldValue: " 15 ") == 15)
        #expect(DuckDBIdleRelease.interval(fromFieldValue: "5") == .seconds(300))
    }

    @Test("A value past the maximum is clamped rather than honoured")
    func clampsToTheMaximum() {
        #expect(DuckDBIdleRelease.minutes(fromFieldValue: "100000") == DuckDBIdleRelease.maximumMinutes)
        #expect(DuckDBIdleRelease.minutes(fromFieldValue: "240") == 240)
    }

    /// The poll is what decides how late a release can be. A quarter of the interval bounds the
    /// lateness at 25%, and the floor and ceiling stop a one-minute setting spinning and a
    /// four-hour setting waking up once an hour and releasing 59 minutes late.
    @Test("The poll interval stays between five and sixty seconds")
    func pollIntervalIsBounded() {
        #expect(DuckDBIdleRelease.pollInterval(for: .seconds(60)) == .seconds(15))
        #expect(DuckDBIdleRelease.pollInterval(for: .seconds(20)) == .seconds(5))
        #expect(DuckDBIdleRelease.pollInterval(for: .seconds(14_400)) == .seconds(60))
    }

    @Test("The field's default value parses as never")
    func defaultValueIsNever() {
        #expect(DuckDBIdleRelease.minutes(fromFieldValue: DuckDBIdleRelease.neverValue) == nil)
    }
}

@Suite("DuckDB access mode")
struct DuckDBAccessModeTests {
    /// Measured against the shipped library: `duckdb_set_config` accepts `READ_ONLY` and
    /// `read_only` and rejects everything else, and a rejected value leaves the database open
    /// read-write with writes allowed. The raw value is the whole guard against that.
    @Test("The raw values are the spellings DuckDB accepts")
    func rawValuesMatchDuckDB() {
        #expect(DuckDBAccessMode.readOnly.rawValue == "READ_ONLY")
        #expect(DuckDBAccessMode.readWrite.rawValue == "READ_WRITE")
        #expect(DuckDBAccessMode.configurationOption == "access_mode")
    }

    @Test("The toggle is honoured for DuckDB's own storage")
    func readOnlyAppliesToDatabaseFiles() {
        let on = [DuckDBAccessMode.fieldId: "true"]
        #expect(DuckDBAccessMode.resolve(fields: on, path: "/data/sales.duckdb") == .readOnly)
        #expect(DuckDBAccessMode.resolve(fields: on, path: "/data/sales.DDB") == .readOnly)
    }

    /// Measured: `access_mode=READ_ONLY` against `:memory:` or a Parquet, CSV or JSON path fails
    /// the open outright with "Cannot launch in-memory database in read-only mode!". None of them
    /// holds a write lock to give up and DuckDB never writes back to them, so the setting is
    /// ignored rather than turned into a connection that refuses to open.
    @Test("The toggle is ignored for anything that cannot carry an access mode")
    func readOnlyIsIgnoredElsewhere() {
        let on = [DuckDBAccessMode.fieldId: "true"]
        for path in [":memory:", "/data/events.parquet", "/data/rows.csv", "/data/rows.json", "/data/rows"] {
            #expect(DuckDBAccessMode.resolve(fields: on, path: path) == .readWrite, "\(path)")
            #expect(DuckDBAccessMode.carriesAccessMode(path: path) == false, "\(path)")
        }
    }

    @Test("An absent or off toggle opens read-write")
    func defaultsToReadWrite() {
        #expect(DuckDBAccessMode.resolve(fields: [:], path: "/data/sales.duckdb") == .readWrite)
        #expect(
            DuckDBAccessMode.resolve(
                fields: [DuckDBAccessMode.fieldId: "false"],
                path: "/data/sales.duckdb"
            ) == .readWrite
        )
    }
}
