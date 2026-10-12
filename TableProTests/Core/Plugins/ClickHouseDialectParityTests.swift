//
//  ClickHouseDialectParityTests.swift
//  TableProTests
//
//  The ClickHouse dialect is declared twice: once on the plugin, and once in the app's curated
//  pre-load table, which is what a completion service gets before the lazy driver bundle activates.
//  Nothing at runtime makes the two agree, and both shipped the same 18 uppercase function names
//  that the server rejects with UNKNOWN_FUNCTION.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ClickHouseDialectParityTests {
    /// Measured on ClickHouse 26.9.1.52 with `SELECT name, case_insensitive FROM system.functions`.
    /// Only the `case_insensitive = 1` rows tolerate any other spelling, and the plugin declares
    /// the rest at their exact catalogue spelling, so an uppercased copy is a broken completion.
    private static let caseSensitiveSpellings = [
        "toString", "toInt32", "formatDateTime", "uniq", "uniqExact",
        "argMin", "argMax", "groupArray", "multiIf", "arrayMap",
        "arrayJoin", "match", "currentDatabase", "quantile", "topK",
        "trim", "ltrim", "rtrim"
    ]

    @Test("The curated pre-load dialect spells every case-sensitive function the way the server does")
    func preloadDialectUsesCatalogueSpellings() throws {
        let functions = try #require(curatedClickHouseDialect()).functions
        let wrong = Self.caseSensitiveSpellings.filter { !functions.contains($0) }
        #expect(
            wrong.isEmpty,
            """
            The curated ClickHouse dialect is served to completion before the driver bundle \
            activates, so these complete to SQL the server rejects: \(wrong.sorted())
            """
        )
    }

    @Test("The curated pre-load dialect declares ClickHouse function names case-sensitive")
    func preloadDialectDeclaresCaseSensitivity() throws {
        #expect(try #require(curatedClickHouseDialect()).functionNamesAreCaseInsensitive == false)
    }

    /// Reads the plugin's own source rather than its type, because a plugin never loads under
    /// XCTest. The two lists have no shared constant to point at: one lives in a plugin target and
    /// one in the app, so this is what stops them drifting apart again.
    @Test("The plugin and the curated table declare the same function vocabulary")
    func pluginAndCuratedTableAgree() throws {
        let curated = try #require(curatedClickHouseDialect()).functions
        let declared = try Self.pluginDeclaredFunctions()

        #expect(!declared.isEmpty, "The ClickHouse plugin source declares a function list")
        #expect(
            declared == curated,
            """
            ClickHousePlugin.swift and PluginMetadataRegistry+RegistryIngredients.swift declare \
            different function vocabularies. Only in plugin: \(declared.subtracting(curated).sorted()). \
            Only in the curated table: \(curated.subtracting(declared).sorted()).
            """
        )
    }

    private func curatedClickHouseDialect() -> SQLDialectDescriptor? {
        PluginMetadataRegistry.shared.builtInDefaults()
            .first { $0.typeId == DatabaseType.clickhouse.rawValue }?
            .snapshot.editor.sqlDialect
    }

    private static func pluginDeclaredFunctions(file: StaticString = #filePath) throws -> Set<String> {
        let source = try repositoryRoot(file: file)
            .appendingPathComponent("Plugins/ClickHouseDriverPlugin/ClickHousePlugin.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        guard let start = text.range(of: "functions: [") else { throw ParityError.sourceNotFound }
        guard let end = text.range(of: "]", range: start.upperBound..<text.endIndex) else {
            throw ParityError.sourceNotFound
        }
        let body = text[start.upperBound..<end.lowerBound]
        return Set(
            body
                .split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["\""]) }
                .filter { !$0.isEmpty }
        )
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
