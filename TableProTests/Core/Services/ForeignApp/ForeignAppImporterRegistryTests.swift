//
//  ForeignAppImporterRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ForeignAppImporterRegistry")
struct ForeignAppImporterRegistryTests {
    @Test("Registry contains all importers")
    func testRegistryContainsAllImporters() {
        let importers = ForeignAppImporterRegistry.all
        #expect(importers.count == 3)

        let ids = importers.map(\.id)
        #expect(ids.contains("tableplus"))
        #expect(ids.contains("sequelace"))
        #expect(ids.contains("dbeaver"))
    }

    @Test("All importers have unique IDs")
    func testAllImportersHaveUniqueIds() {
        let importers = ForeignAppImporterRegistry.all
        let ids = importers.map(\.id)
        let uniqueIds = Set(ids)
        #expect(uniqueIds.count == ids.count)
    }

    @Test("All importers have display names")
    func testAllImportersHaveDisplayNames() {
        let importers = ForeignAppImporterRegistry.all
        for importer in importers {
            #expect(!importer.displayName.isEmpty, "\(importer.id) should have a display name")
        }
    }

    @Test("All importers have symbol names")
    func testAllImportersHaveSymbolNames() {
        let importers = ForeignAppImporterRegistry.all
        for importer in importers {
            #expect(!importer.symbolName.isEmpty, "\(importer.id) should have a symbol name")
        }
    }

    @Test("All importers have bundle identifiers")
    func testAllImportersHaveBundleIdentifiers() {
        let importers = ForeignAppImporterRegistry.all
        for importer in importers {
            #expect(!importer.appBundleIdentifier.isEmpty, "\(importer.id) should have a bundle identifier")
        }
    }

    @Test("TablePlus importer has correct metadata")
    func testTablePlusImporterMetadata() {
        let importer = TablePlusImporter()
        #expect(importer.id == "tableplus")
        #expect(importer.displayName == "TablePlus")
        #expect(importer.appBundleIdentifier == "com.tinyapp.TablePlus")
    }

    @Test("Sequel Ace importer has correct metadata")
    func testSequelAceImporterMetadata() {
        let importer = SequelAceImporter()
        #expect(importer.id == "sequelace")
        #expect(importer.displayName == "Sequel Ace")
        #expect(importer.appBundleIdentifier == "com.sequel-ace.sequel-ace")
    }

    @Test("DBeaver importer has correct metadata")
    func testDBeaverImporterMetadata() {
        let importer = DBeaverImporter()
        #expect(importer.id == "dbeaver")
        #expect(importer.displayName == "DBeaver")
        #expect(importer.appBundleIdentifier == "org.jkiss.dbeaver.core.product")
    }
}
