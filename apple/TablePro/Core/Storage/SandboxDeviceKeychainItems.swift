//
//  SandboxDeviceKeychainItems.swift
//  TablePro
//

import Foundation
import Security

// The sync engine's device items as a file in the sandbox, so a UI test's engine never reads or replaces the
// installation's keys and anchor, which share their names.
internal final class SandboxDeviceKeychainItems: DeviceKeychainItems, @unchecked Sendable {
    private let file: JSONFileStore<[String: Data]>
    private let lock = NSLock()

    internal init(fileURL: URL) {
        file = JSONFileStore(url: fileURL)
    }

    internal func add(_ attributes: [String: Any]) -> OSStatus {
        change { items in
            let name = Self.name(attributes)
            guard items[name] == nil else { return errSecDuplicateItem }
            items[name] = attributes[kSecValueData as String] as? Data ?? Data()
            return errSecSuccess
        }
    }

    internal func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        change { items in
            let name = Self.name(query)
            guard items[name] != nil else { return errSecItemNotFound }
            if let data = attributes[kSecValueData as String] as? Data {
                items[name] = data
            }
            return errSecSuccess
        }
    }

    internal func copyData(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        switch file.read() {
        case .missing:
            return (errSecItemNotFound, nil)
        case .unreadable:
            return (errSecDecode, nil)
        case .value(let items):
            guard let data = items[Self.name(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }

    internal func delete(_ query: [String: Any]) -> OSStatus {
        change { items in
            items.removeValue(forKey: Self.name(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    // A file that does not read is never written over, as a Keychain that cannot be read is never treated as empty.
    private func change(_ body: (inout [String: Data]) -> OSStatus) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        var items: [String: Data]
        switch file.read() {
        case .missing:
            items = [:]
        case .unreadable:
            return errSecDecode
        case .value(let stored):
            items = stored
        }
        let status = body(&items)
        guard status == errSecSuccess else { return status }
        return (try? file.write(items)) == nil ? errSecIO : errSecSuccess
    }

    private static func name(_ query: [String: Any]) -> String {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return "\(service)/\(account)"
    }
}
