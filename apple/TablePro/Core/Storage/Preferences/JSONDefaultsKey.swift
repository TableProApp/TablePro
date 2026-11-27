//
//  JSONDefaultsKey.swift
//  TablePro
//

import Foundation

// A defaults entry holding one JSON-encoded value. Plain property list values keep `DefaultsKey`.
internal struct JSONDefaultsKey<Value>: Sendable {
    internal let name: String
    internal let coding: StoreCoding

    internal init(_ name: String, coding: StoreCoding = .plain) {
        self.name = name
        self.coding = coding
    }
}

internal extension KeyValueStore {
    func read<Value: Decodable>(_ key: JSONDefaultsKey<Value>) -> StoreRead<Value> {
        guard let data = dataValue(forKey: key.name) else { return .missing }
        do {
            return .value(try key.coding.decode(Value.self, from: data))
        } catch {
            StoreLog.unreadable(key.name, error)
            return .unreadable(error)
        }
    }

    func write<Value: Encodable>(_ value: Value, to key: JSONDefaultsKey<Value>) throws {
        do {
            setDataValue(try key.coding.encode(value), forKey: key.name)
        } catch {
            StoreLog.unwritable(key.name, error)
            throw error
        }
    }

    func removeValue<Value>(for key: JSONDefaultsKey<Value>) {
        setDataValue(nil, forKey: key.name)
    }
}
