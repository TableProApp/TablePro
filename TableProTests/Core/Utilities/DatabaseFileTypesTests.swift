//
//  DatabaseFileTypesTests.swift
//  TableProTests
//
//  Whether an extension resolves to a registered type or a minted dynamic one depends on
//  what is installed on the machine: a Mac with the DuckDB CLI resolves `duckdb` and `ddb`
//  to one shared `org.duckdb.duckdb-database`, a Mac without it mints a dynamic type for
//  each. These assert what holds either way, so they mean the same thing on CI.
//

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TablePro

@Suite("Database file types")
struct DatabaseFileTypesTests {
    private func accepts(_ types: [UTType], _ fileExtension: String) -> Bool {
        types.contains { type in
            type.tags[.filenameExtension]?.contains(fileExtension) ?? false
        }
    }

    @Test("Every declared extension is accepted, including ones with no registered type")
    func everyExtensionIsAccepted() {
        let extensions = ["duckdb", "ddb", "parquet", "csv", "tsv", "json", "ndjson"]
        let types = DatabaseFileTypes.contentTypes(forExtensions: extensions)

        for fileExtension in extensions {
            #expect(accepts(types, fileExtension), "the panel would reject .\(fileExtension)")
        }
    }

    @Test("An unregistered extension still produces a type that conforms to data")
    func unregisteredExtensionsStillResolve() {
        let types = DatabaseFileTypes.contentTypes(forExtensions: ["duckdb", "ddb"])
        #expect(!types.isEmpty)
        #expect(types.allSatisfy { $0.conforms(to: .data) })
        #expect(accepts(types, "duckdb"))
        #expect(accepts(types, "ddb"))
    }

    @Test("Extensions that share one system type are listed once")
    func sharedTypesAreDeduplicated() {
        let types = DatabaseFileTypes.contentTypes(forExtensions: ["csv", "csv", "json"])
        #expect(types.count == Set(types).count)
        #expect(types.count == 2)
    }

    @Test("The first extension keeps its place, so the panel's default format is the driver's")
    func orderIsPreserved() {
        let types = DatabaseFileTypes.contentTypes(forExtensions: ["parquet", "csv"])
        #expect(types.first?.tags[.filenameExtension]?.contains("parquet") == true)
    }

    @Test("A leading dot or stray whitespace is tolerated")
    func extensionsAreTrimmed() {
        let types = DatabaseFileTypes.contentTypes(forExtensions: [".parquet", " csv "])
        #expect(accepts(types, "parquet"))
        #expect(accepts(types, "csv"))
    }

    /// A driver that declares nothing must not end up with a panel that allows nothing.
    @Test("A driver with no declared extensions falls back to any file")
    func emptyListFallsBackToData() {
        #expect(DatabaseFileTypes.contentTypes(forExtensions: []) == [.data])
        #expect(DatabaseFileTypes.contentTypes(forExtensions: ["", ".", "  "]) == [.data])
    }
}
