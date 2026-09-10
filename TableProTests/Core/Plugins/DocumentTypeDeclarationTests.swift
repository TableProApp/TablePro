//
//  DocumentTypeDeclarationTests.swift
//  TableProTests
//
//  Every file format the app claims from LaunchServices has to be declared twice, as a document
//  type and as the imported UTI it names, or Finder never offers TablePro for it.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("Bundle document type declarations")
struct DocumentTypeDeclarationTests {
    private func infoPlist() throws -> [String: Any] {
        let plistURL = Bundle(for: AppDelegate.self)
            .bundleURL
            .appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plistObject = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plistObject as? [String: Any])
    }

    private func documentType(forContentType contentType: String) throws -> [String: Any] {
        let documentTypes = try #require(try infoPlist()["CFBundleDocumentTypes"] as? [[String: Any]])
        return try #require(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?.contains(contentType) == true
        })
    }

    private func importedType(_ identifier: String) throws -> [String: Any] {
        let imported = try #require(try infoPlist()["UTImportedTypeDeclarations"] as? [[String: Any]])
        return try #require(imported.first { $0["UTTypeIdentifier"] as? String == identifier })
    }

    @Test("Parquet is claimed as a read-only alternate handler")
    func claimsParquet() throws {
        let documentType = try documentType(forContentType: "org.apache.parquet")

        #expect(documentType["CFBundleTypeExtensions"] as? [String] == ["parquet"])
        /// DuckDB opens a Parquet file as read-only views, so Viewer is the honest role, and no
        /// app owns the format, so Alternate leaves a dedicated tool its association.
        #expect(documentType["CFBundleTypeRole"] as? String == "Viewer")
        #expect(documentType["LSHandlerRank"] as? String == "Alternate")

        let tags = try #require(try importedType("org.apache.parquet")["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == ["parquet"])
    }

    @Test("Every extension a signature-bearing driver declares is claimed by the bundle", arguments: [
        ("org.sqlite.sqlite", "SQLite"),
        ("org.duckdb.duckdb-database", "DuckDB")
    ])
    func claimsEveryDeclaredExtension(contentType: String, typeId: String) throws {
        let claimed = try #require(try documentType(forContentType: contentType)["CFBundleTypeExtensions"] as? [String])
        let tags = try #require(try importedType(contentType)["UTTypeTagSpecification"] as? [String: Any])

        #expect(tags["public.filename-extension"] as? [String] == claimed)
        #expect(!claimed.isEmpty)

        let declared = PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: typeId)?.schema.fileExtensions ?? []
        for fileExtension in claimed {
            #expect(declared.contains(fileExtension), "the driver does not open .\(fileExtension)")
        }
    }
}
