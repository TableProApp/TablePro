import Foundation
import os
import Security
@testable import TablePro
import TableProFFI
import Testing

private final class RecordingDeviceKeychain: DeviceKeychainItems, @unchecked Sendable {
    let queries = OSAllocatedUnfairLock<[[String: Any]]>(uncheckedState: [])

    var services: [String] {
        queries.withLockUnchecked { $0.map { $0[kSecAttrService as String] as? String ?? "" } }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        record(attributes)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        record(query)
    }

    func copyData(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        (record(query), nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        record(query)
    }

    private func record(_ query: [String: Any]) -> OSStatus {
        queries.withLockUnchecked { $0.append(query) }
        return errSecItemNotFound
    }
}

struct ProfileDeviceKeychainItemsTests {
    @Test("A device profile's sync items take a service of its own, with the rest of each query as the store wrote it")
    func everyCallTakesTheProfilesService() throws {
        let keychain = RecordingDeviceKeychain()
        let store = KeychainDeviceStore(
            items: ProfileDeviceKeychainItems(base: keychain, profile: "device-a"),
            accessGroup: "TEAMID.com.TablePro.shared",
            passcodeIsSet: { true }
        )
        let item = DeviceItemTag.anchorRoot(state: "STATE")

        _ = try store.load(item: item)
        try store.store(item: item, value: Data([1]))
        try store.delete(item: item)

        #expect(keychain.services.count == 4)
        #expect(keychain.services.allSatisfy { $0 == "com.TablePro.sync.device.profile.device-a" })
        let first = try #require(keychain.queries.withLockUnchecked { $0.first })
        #expect(first[kSecAttrAccount as String] as? String == KeychainDeviceStore.account(item))
        #expect(first[kSecAttrAccessGroup as String] as? String == "TEAMID.com.TablePro.shared")
        #expect(first[kSecAttrSynchronizable as String] as? Bool == false)
    }
}
