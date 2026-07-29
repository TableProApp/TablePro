//
//  SQLiteFileExtensionsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("SQLite file extension registration")
struct SQLiteFileExtensionsTests {
    private static let canonical: [String] = ["db", "db3", "s3db", "sl3", "sqlite", "sqlite3", "sqlitedb"]

    @Test("Plugin metadata registry exposes the canonical SQLite extensions")
    func registryHasCanonicalExtensions() throws {
        let snapshot = try #require(PluginMetadataRegistry.shared.snapshot(forTypeId: "SQLite"))
        #expect(snapshot.schema.fileExtensions.sorted() == Self.canonical.sorted())
    }

    @Test("URLClassifier resolves every canonical extension to the SQLite database type")
    func urlClassifierResolvesEveryExtension() {
        let extensionMap = PluginManager.shared.allRegisteredFileExtensions
        for ext in Self.canonical {
            #expect(extensionMap[ext] != nil, "extension \(ext) is not registered")
        }
    }
}
