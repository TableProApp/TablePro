//
//  OracleCuratedParityTests.swift
//  TableProTests
//
//  Oracle's type lists and paging are declared twice: by the plugin, and in the app's curated entry, which is what
//  the Structure type picker and completion get until the registry plugin is installed. The two drifted before, the
//  curated picker kept an empty Boolean group, so this holds them to one list.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct OracleCuratedParityTests {
    private func curatedOracle() throws -> PluginMetadataSnapshot {
        try #require(
            PluginMetadataRegistry.shared.builtInDefaults().first { $0.typeId == DatabaseType.oracle.rawValue }?.snapshot
        )
    }

    @Test("The curated type picker groups Oracle's types as the plugin does")
    func columnTypesMatchThePlugin() throws {
        #expect(try curatedOracle().editor.columnTypesByCategory == OracleTypeCatalog.columnTypesByCategory)
    }

    @Test("The curated completion list names every type the plugin offers, once")
    func dataTypesMatchThePlugin() throws {
        let curated = try #require(try curatedOracle().editor.sqlDialect).dataTypes
        #expect(curated == Set(OracleTypeCatalog.dataTypes))
        #expect(Set(OracleTypeCatalog.dataTypes).count == OracleTypeCatalog.dataTypes.count)
    }

    @Test("Every type the picker offers is one completion offers")
    func pickerTypesAreCompletable() throws {
        let snapshot = try curatedOracle()
        let completable = try #require(snapshot.editor.sqlDialect).dataTypes
        let offered = Set(snapshot.editor.columnTypesByCategory.values.flatMap { $0 })
        #expect(offered.subtracting(completable).isEmpty)
        #expect(offered.isSuperset(of: ["BOOLEAN", "JSON", "VECTOR"]))
    }

    /// `ORDER BY 1` sorts by the first column, and a LOB first column fails the whole page with ORA-22848. The plugin
    /// declares none, and the curated entry is what pages a table before the plugin loads.
    @Test("The curated dialect pages without an ORDER BY, as the plugin does")
    func pagingMatchesThePlugin() throws {
        let curated = try #require(try curatedOracle().editor.sqlDialect).offsetFetchOrderBy
        #expect(curated.isEmpty)
        #expect(try Self.pluginOffsetFetchOrderBy() == [curated])
    }

    @Test("A keyless Oracle row match leaves out every column Oracle cannot compare with =")
    func keylessMatchLeavesOutUncomparableColumns() throws {
        let prefixes = try curatedOracle().schema.rowMatchExcludedTypePrefixes
        let columns = [
            ColumnInfo(name: "ID", dataType: "NUMBER(10)", isNullable: false, isPrimaryKey: false),
            ColumnInfo(name: "NAME", dataType: "NVARCHAR2(100)", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "CODE", dataType: "VARCHAR2(50 CHAR)", isNullable: true, isPrimaryKey: false),
            ColumnInfo(
                name: "CREATED", dataType: "DATE", isNullable: true, isPrimaryKey: false,
                classificationTypeName: "TIMESTAMP(0)"
            ),
            ColumnInfo(name: "AT", dataType: "TIMESTAMP(6) WITH TIME ZONE", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "BYTES", dataType: "RAW(16)", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "NOTES", dataType: "CLOB", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "BODY", dataType: "NCLOB", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "PHOTO", dataType: "BLOB", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "LEGACY", dataType: "LONG", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "OLD_BYTES", dataType: "LONG RAW", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "SCAN", dataType: "BFILE", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "DOC", dataType: "XMLTYPE", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "DATA", dataType: "JSON", isNullable: true, isPrimaryKey: false),
            ColumnInfo(name: "EMBEDDING", dataType: "VECTOR(3, FLOAT32)", isNullable: true, isPrimaryKey: false),
            ColumnInfo(
                name: "SHAPE", dataType: "\"MDSYS\".\"SDO_GEOMETRY\"", isNullable: true, isPrimaryKey: false,
                ddlSpelling: "\"MDSYS\".\"SDO_GEOMETRY\"", classificationTypeName: "SDO_GEOMETRY"
            )
        ]

        #expect(
            QueryExecutor.columns(in: columns, typedAnyOf: prefixes)
                == ["NOTES", "BODY", "PHOTO", "LEGACY", "OLD_BYTES", "SCAN", "DOC", "DATA", "EMBEDDING", "SHAPE"]
        )
    }

    @Test("Oracle compares no column through a text conversion, which it has no CONCAT form for")
    func noTextComparedColumns() throws {
        #expect(try curatedOracle().schema.rowMatchTextTypePrefixes.isEmpty)
    }

    /// Read from the plugin's source because its type list is shared with the tests but its dialect is not: the
    /// dialect lives on the plugin class, which links the Oracle driver core.
    private static func pluginOffsetFetchOrderBy(file: StaticString = #filePath) throws -> [String] {
        let directory = try repositoryRoot(file: file).appendingPathComponent("Plugins/OracleDriverPlugin")
        let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"offsetFetchOrderBy:\s*"([^"]*)""#)
        return try sources.flatMap { url -> [String] in
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
    }

    private static func repositoryRoot(file: StaticString) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Plugins/TableProPluginKit/DriverPlugin.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        throw ParityError.sourceNotFound
    }

    private enum ParityError: Error {
        case sourceNotFound
    }
}
