//
//  MySQLResultSynthesisSourceScanTests.swift
//  TableProTests
//

import Foundation
import Testing

/// The MySQL driver used to answer a `SELECT` that produced no result set by scraping a name out of
/// the statement text and describing it, so `SELECT COUNT(*) INTO @c FROM users` came back carrying
/// the columns of `users`, and a catalog read a proxy declined came back as
/// `1146 Table 'db.information_schema' doesn't exist`. A result set is the server's answer, so the
/// driver never sends a statement of its own to invent one. The plugin imports CMariaDB, which this
/// target cannot, so the guard is a source scan.
struct MySQLResultSynthesisSourceScanTests {
    private static let pluginDirectory: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 { directory.deleteLastPathComponent() }
        return directory
            .appendingPathComponent("Plugins")
            .appendingPathComponent("MySQLDriverPlugin")
    }()

    private static func pluginSources() throws -> [(name: String, text: String)] {
        try FileManager.default
            .contentsOfDirectory(at: pluginDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("The driver reads no table name out of a statement it was handed")
    func noStatementTextIsScrapedForATableName() throws {
        let sources = try Self.pluginSources()
        #expect(!sources.isEmpty, "The scan found no plugin sources, so it checked nothing")

        /// `MySQLSelectLimitStatement` matches a bare `\bFROM\b` to reconcile `SQL_SELECT_LIMIT`,
        /// which reads nothing out of the statement. What is banned is capturing the name after it.
        let offenders = sources.filter { source in
            source.text.contains("bFROM\\s+[") || source.text.contains("extractTableName")
        }
        #expect(
            offenders.map(\.name).isEmpty,
            "A statement's text is not a catalog: \(offenders.map(\.name))"
        )
    }

    @Test("An empty result is never filled in with columns the server did not send")
    func emptyResultsAreNotSynthesized() throws {
        let sources = try Self.pluginSources()

        let offenders = sources.filter { source in
            source.text.contains("columns.isEmpty && result.rows.isEmpty")
                || source.text.contains("fetchColumnNames")
        }
        #expect(
            offenders.map(\.name).isEmpty,
            "A result set with no columns means the statement produced none: \(offenders.map(\.name))"
        )
    }
}
