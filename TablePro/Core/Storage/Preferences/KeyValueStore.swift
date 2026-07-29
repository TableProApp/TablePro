//
//  KeyValueStore.swift
//  TablePro
//

import Foundation

protocol KeyValueStore: AnyObject {
    func dataValue(forKey key: String) -> Data?
    func setDataValue(_ data: Data?, forKey key: String)
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
}
