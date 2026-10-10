//
//  ForeignAppImporterRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProPluginKit
import Testing

struct ForeignAppImporterRegistryTests {
    @Test("Registry contains all importers")
    func testRegistryContainsAllImporters() {
        let importers = ForeignAppImporterRegistry.all
        #expect(importers.count == 6)

        let ids = importers.map(\.id)
        #expect(ids.contains("tableplus"))
        #expect(ids.contains("sequelace"))
        #expect(ids.contains("dbeaver"))
        #expect(ids.contains("datagrip"))
        #expect(ids.contains("beekeeperstudio"))
        #expect(ids.contains("navicat"))
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

    @Test("Beekeeper Studio importer has correct metadata")
    func testBeekeeperStudioImporterMetadata() {
        let importer = BeekeeperStudioImporter()
        #expect(importer.id == "beekeeperstudio")
        #expect(importer.displayName == "Beekeeper Studio")
        #expect(importer.appBundleIdentifier == "io.beekeeperstudio.desktop")
    }

    @Test("Navicat importer has correct metadata")
    func testNavicatImporterMetadata() {
        let importer = NavicatImporter()
        #expect(importer.id == "navicat")
        #expect(importer.displayName == "Navicat")
        #expect(importer.appBundleIdentifier == "com.navicat.NavicatPremium")
        #expect(importer.importFileTypes != nil)
    }

    @Test("Importers declare whether passwords are read from the keychain")
    func testReadsPasswordsFromKeychainFlags() {
        #expect(TablePlusImporter().readsPasswordsFromKeychain == true)
        #expect(SequelAceImporter().readsPasswordsFromKeychain == true)
        #expect(DataGripImporter().readsPasswordsFromKeychain == true)
        #expect(DBeaverImporter().readsPasswordsFromKeychain == false)
        #expect(BeekeeperStudioImporter().readsPasswordsFromKeychain == false)
        #expect(NavicatImporter().readsPasswordsFromKeychain == false)
    }

    @Test("Keychain confirmation applies only to keychain-based importers when importing passwords")
    func testRequiresKeychainConfirmation() {
        #expect(ImportFromAppSheet.requiresKeychainConfirmation(includePasswords: true, importer: TablePlusImporter()))
        #expect(!ImportFromAppSheet.requiresKeychainConfirmation(includePasswords: true, importer: DBeaverImporter()))
        #expect(!ImportFromAppSheet.requiresKeychainConfirmation(includePasswords: false, importer: TablePlusImporter()))
    }

    @Test("Every importer but Navicat reads saved queries, each with its caption")
    func testSavedQuerySupport() {
        for importer in ForeignAppImporterRegistry.all {
            switch importer.savedQuerySupport {
            case .reads(let caption):
                #expect(importer.id != "navicat", "\(importer.id) should not read saved queries")
                #expect(!caption.isEmpty)
            case .unavailable(let reason):
                #expect(importer.id == "navicat", "\(importer.id) should read saved queries")
                #expect(!reason.isEmpty)
            }
        }
    }

    @Test("inventory runs off the main actor and finds nothing in empty sources")
    func testInventoryOffMainActor() async throws {
        let empty = try ForeignFixture.makeTempDirectory("ForeignAppImporterRegistryTests")
        let importers = Self.importers(rootedAt: empty)

        let inventories = await withTaskGroup(of: ForeignAppInventory.self) { group in
            for importer in importers {
                group.addTask { importer.inventory() }
            }
            var collected: [ForeignAppInventory] = []
            for await inventory in group {
                collected.append(inventory)
            }
            return collected
        }

        #expect(inventories.count == importers.count)
        #expect(inventories.allSatisfy { $0 == ForeignAppInventory(connections: 0, savedQueries: 0) })
    }

    private static func importers(rootedAt root: URL) -> [any ForeignAppImporter] {
        var tablePlus = TablePlusImporter()
        tablePlus.dataDirectoryOverride = root
        tablePlus.readViewSetting = { _ in nil }
        tablePlus.resolveAppURL = { _ in nil }

        var sequelAce = SequelAceImporter()
        sequelAce.favoritesFileURL = root.appendingPathComponent("Favorites.plist")
        sequelAce.queryFavoritesFileURL = root.appendingPathComponent("com.sequel-ace.sequel-ace.plist")

        var dbeaver = DBeaverImporter()
        dbeaver.dbeaverDataRoot = root

        var dataGrip = DataGripImporter()
        dataGrip.jetBrainsRoot = root

        var beekeeper = BeekeeperStudioImporter()
        beekeeper.dataDirectoryURL = root

        return [tablePlus, sequelAce, dbeaver, dataGrip, beekeeper, NavicatImporter()]
    }
}
