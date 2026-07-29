//
//  BeancountDriverMetadataTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("Beancount driver metadata")
struct BeancountDriverMetadataTests {
    @Test("registry exposes Beancount as a downloadable file-based driver")
    func registryMetadata() throws {
        let snapshot = try #require(PluginMetadataRegistry.shared.snapshot(forTypeId: "Beancount"))
        #expect(snapshot.displayName == "Beancount")
        #expect(snapshot.isDownloadable == true)
        #expect(snapshot.connectionMode == .fileBased)
        #expect(snapshot.schema.fileExtensions == ["beancount"])
        #expect(snapshot.pathFieldRole == .filePath)
        #expect(snapshot.supportsSchemaEditing == false)
        #expect(snapshot.supportsDatabaseSwitching == false)
        #expect(snapshot.supportsHealthMonitor == false)
    }

    @Test("URLClassifier resolves .beancount files to the Beancount database type")
    func urlClassifierResolvesBeancountFiles() {
        #expect(PluginManager.shared.allRegisteredFileExtensions["beancount"] == DatabaseType(rawValue: "Beancount"))
    }

    @Test("app bundle claims .beancount files as the owner viewer")
    func appBundleClaimsBeancountFilesAsOwnerViewer() throws {
        let plistURL = Bundle(for: AppDelegate.self)
            .bundleURL
            .appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plistObject = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(plistObject as? [String: Any])
        let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let beancountDocumentType = try #require(documentTypes.first { documentType in
            let contentTypes = documentType["LSItemContentTypes"] as? [String]
            return contentTypes?.contains("com.tablepro.beancount") == true
        })

        #expect(beancountDocumentType["CFBundleTypeRole"] as? String == "Viewer")
        #expect(beancountDocumentType["LSHandlerRank"] as? String == "Owner")
        #expect(beancountDocumentType["CFBundleTypeExtensions"] as? [String] == ["beancount"])

        let exportedTypes = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let beancountType = try #require(exportedTypes.first {
            $0["UTTypeIdentifier"] as? String == "com.tablepro.beancount"
        })
        let tags = try #require(beancountType["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == ["beancount"])
    }
}
