//
//  SyncMetadataStorageEnvironmentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing
import TableProSyncTransport

struct SyncMetadataStorageEnvironmentTests {
    @Test("The app's sync metadata storage writes into the app storage environment's defaults")
    func appDefaultFollowsTheStorageEnvironment() {
        #expect(SyncMetadataStorage.appDefault.userDefaults === AppStorageEnvironment.shared.defaults)
    }

    @Test("A storage built for a suite never touches the standard domain")
    func injectedStorageStaysInItsSuite() throws {
        let suiteName = "syncmetadata-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = SyncMetadataStorage(userDefaults: defaults)
        let id = UUID().uuidString
        storage.markDirty(id, type: .settings)
        storage.addTombstone(id, type: .settings)

        #expect(storage.dirtyIds(for: .settings).contains(id))
        #expect(storage.tombstones(for: .settings).contains { $0.id == id })

        let standardDirty = UserDefaults.standard.stringArray(forKey: "com.TablePro.sync.dirty.settings") ?? []
        #expect(!standardDirty.contains(id))
    }
}
