//
//  StoreRead.swift
//  TablePro
//

import Foundation
import os

// What a stored value read back as. Missing and unreadable differ: a store must not write over data it could not read.
internal enum StoreRead<Value> {
    case missing
    case value(Value)
    case unreadable(any Error)

    internal var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    internal var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }

    internal func map<Mapped>(_ transform: (Value) -> Mapped) -> StoreRead<Mapped> {
        switch self {
        case .missing: return .missing
        case .value(let value): return .value(transform(value))
        case .unreadable(let error): return .unreadable(error)
        }
    }
}

// The JSON shape a store writes. Changing it for an existing store breaks the previous stable's read.
internal struct StoreCoding: @unchecked Sendable {
    internal let encoder: JSONEncoder
    internal let decoder: JSONDecoder

    internal static let plain = StoreCoding(encoder: JSONEncoder(), decoder: JSONDecoder())

    internal static let sortedKeys: StoreCoding = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return StoreCoding(encoder: encoder, decoder: JSONDecoder())
    }()

    internal static let prettyISO8601: StoreCoding = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return StoreCoding(encoder: encoder, decoder: decoder)
    }()

    internal func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(value)
    }

    internal func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try decoder.decode(type, from: data)
    }
}

internal enum StoreLog {
    static let logger = Logger(subsystem: "com.TablePro", category: "Store")

    static func unreadable(_ name: String, _ error: any Error) {
        logger.error("Unreadable \(name, privacy: .public): \(error.publicLogShape, privacy: .public)")
    }

    static func unwritable(_ name: String, _ error: any Error) {
        logger.error("Could not save \(name, privacy: .public): \(error.publicLogShape, privacy: .public)")
    }
}
