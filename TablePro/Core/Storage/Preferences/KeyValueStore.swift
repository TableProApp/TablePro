//
//  KeyValueStore.swift
//  TablePro
//

import Foundation

protocol KeyValueStore: AnyObject, Sendable {
    func dataValue(forKey key: String) -> Data?
    func setDataValue(_ data: Data?, forKey key: String)
    func keys(withPrefix prefix: String) -> [String]
}

internal extension KeyValueStore {
    func moveValue(fromKey oldKey: String, toKey newKey: String) {
        guard oldKey != newKey, let data = dataValue(forKey: oldKey) else { return }
        setDataValue(data, forKey: newKey)
        setDataValue(nil, forKey: oldKey)
    }

    func moveValues(withPrefix oldPrefix: String, toPrefix newPrefix: String) {
        guard oldPrefix != newPrefix else { return }
        for key in keys(withPrefix: oldPrefix) {
            moveValue(fromKey: key, toKey: newPrefix + key.dropFirst(oldPrefix.count))
        }
    }

    func removeValues(withPrefix prefix: String) {
        for key in keys(withPrefix: prefix) {
            setDataValue(nil, forKey: key)
        }
    }
}

extension UserDefaults: KeyValueStore {
    func dataValue(forKey key: String) -> Data? {
        data(forKey: key)
    }

    func setDataValue(_ data: Data?, forKey key: String) {
        guard let data else {
            removeObject(forKey: key)
            return
        }
        set(data, forKey: key)
    }

    func keys(withPrefix prefix: String) -> [String] {
        dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    }
}
