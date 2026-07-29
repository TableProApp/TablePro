//
//  LinkedFolderStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Linked folder stores")
struct LinkedFolderStoreTests {
    @Test("LinkedFolderStorage adds and removes through the shared implementation")
    func linkedFolderRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "linkedfolder-\(UUID().uuidString)"))
        let storage = LinkedFolderStorage(defaults: defaults)
        let folder = LinkedFolder(path: "/tmp/exports")
        storage.addFolder(folder)
        #expect(storage.loadFolders().map(\.id) == [folder.id])
        storage.removeFolder(folder)
        #expect(storage.loadFolders().isEmpty)
    }

    @Test("LinkedSQLFolderStorage updates through the shared implementation")
    func linkedSQLFolderUpdates() throws {
        let defaults = try #require(UserDefaults(suiteName: "linkedsqlfolder-\(UUID().uuidString)"))
        let storage = LinkedSQLFolderStorage(defaults: defaults)
        var folder = LinkedSQLFolder(path: "/tmp/queries")
        storage.addFolder(folder)
        folder.isEnabled = false
        storage.updateFolder(folder)
        #expect(storage.loadFolders() == [folder])
    }
}
