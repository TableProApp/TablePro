//
//  ProfileDeviceKeychainItems.swift
//  TablePro
//

import Foundation
import Security

// A Debug device profile's sync device items: the same data protection Keychain and access group, under a service of
// the profile's own, so its keys and anchors never meet the real store's items, which share their names.
nonisolated struct ProfileDeviceKeychainItems: DeviceKeychainItems {
    let base: any DeviceKeychainItems
    let profile: String

    func add(_ attributes: [String: Any]) -> OSStatus {
        base.add(scoped(attributes))
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        base.update(scoped(query), attributes: attributes)
    }

    func copyData(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        base.copyData(scoped(query))
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        base.delete(scoped(query))
    }

    private func scoped(_ query: [String: Any]) -> [String: Any] {
        var query = query
        let service = query[kSecAttrService as String] as? String ?? ""
        query[kSecAttrService as String] = "\(service).profile.\(profile)"
        return query
    }
}
