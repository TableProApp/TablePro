//
//  KeychainNoticeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct KeychainNoticeTests {
    private let inventory = ForeignAppInventory(connections: 4, savedQueries: 0, keychainPrompts: 9)
    private let withPasswords = ForeignImportRequest(includePasswords: true, includeSavedQueries: false)
    private let withoutPasswords = ForeignImportRequest(includePasswords: false, includeSavedQueries: true)

    @Test("A Keychain source read with passwords gets a notice naming the app and the real prompt count")
    func keychainSourceWithPasswords() throws {
        let notice = try #require(KeychainNotice.needed(for: TablePlusImporter(), request: withPasswords, inventory: inventory))

        #expect(notice == KeychainNotice(id: "tableplus", appName: "TablePlus", promptCount: 9))
        #expect(notice.message.contains("9"))
        #expect(notice.message.contains("TablePlus"))
    }

    @Test("No notice without passwords, for a source that decrypts its own file, or with no item to ask for")
    func noNoticeOtherwise() {
        let nothingStored = ForeignAppInventory(connections: 2, savedQueries: 0, keychainPrompts: 0)

        #expect(KeychainNotice.needed(for: TablePlusImporter(), request: withoutPasswords, inventory: inventory) == nil)
        #expect(KeychainNotice.needed(for: DBeaverImporter(), request: withPasswords, inventory: inventory) == nil)
        #expect(KeychainNotice.needed(for: NavicatImporter(), request: withPasswords, inventory: inventory) == nil)
        #expect(KeychainNotice.needed(for: SequelAceImporter(), request: withPasswords, inventory: nothingStored) == nil)
    }

    @Test("Every importer that reads the Keychain asks first")
    func everyKeychainImporterAsks() {
        for importer in ForeignAppImporterRegistry.all {
            let notice = KeychainNotice.needed(for: importer, request: withPasswords, inventory: inventory)
            #expect((notice != nil) == importer.readsPasswordsFromKeychain, "\(importer.id)")
        }
    }

    @Test("The menu import defaults passwords off for a Keychain source and on for one that decrypts its file")
    func passwordDefaults() {
        let rows = ForeignAppImporterRegistry.all.map {
            ForeignSourceRow(importer: $0, availability: .available, inventory: inventory)
        }

        for row in rows {
            let request = ForeignSourcePickerModel.defaultRequest(for: row)
            #expect(request.includePasswords == !row.importer.readsPasswordsFromKeychain, "\(row.id)")
        }
    }
}
