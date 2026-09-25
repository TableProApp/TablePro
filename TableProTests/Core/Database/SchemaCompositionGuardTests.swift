//
//  SchemaCompositionGuardTests.swift
//  TableProTests
//

import Foundation
import Testing

struct SchemaCompositionGuardTests {
    private static let appDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("TablePro")
    }()

    private static let composerEntryPoints = [
        "SchemaStatementGenerator(",
        "CreateTableStatementComposer.compose(",
        "generateCreateTableStatements("
    ]

    private static let scopedComposers: Set<String> = [
        "DatabaseManager+SchemaComposition.swift",
        "StructureTableRebuildHandler.swift"
    ]

    private static let knownUnscopedComposers: Set<String> = [
        "SchemaSyncScriptBuilder.swift"
    ]

    private static func appSources() throws -> [(name: String, text: String)] {
        guard let enumerator = FileManager.default.enumerator(
            at: appDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return try enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("The scan reaches the app sources and the scoped composer")
    func sourcesAreReachable() throws {
        let sources = try Self.appSources()
        #expect(sources.count > 100, "The app sources were not found; the guard below would pass vacuously")
        #expect(sources.contains { $0.name == "DatabaseManager+SchemaComposition.swift" })
    }

    @Test("DDL is composed only on a driver leased for the statement's own scope")
    func ddlIsComposedOnlyOnAScopedDriver() throws {
        let allowed = Self.scopedComposers.union(Self.knownUnscopedComposers)
        let offenders = try Self.appSources()
            .filter { !allowed.contains($0.name) }
            .filter { source in Self.composerEntryPoints.contains { source.text.contains($0) } }
            .map(\.name)

        #expect(offenders.isEmpty, "These files compose DDL outside a scoped lease: \(offenders)")
    }
}
