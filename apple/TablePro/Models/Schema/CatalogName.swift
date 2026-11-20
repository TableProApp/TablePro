//
//  CatalogName.swift
//  TablePro
//

import Foundation

// A server keeps apart names Swift's String equates (NFC and NFD spellings), so a name read from the catalog keys and
// matches by its UTF-8 bytes.
struct CatalogName: Hashable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringInterpolation {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    init(stringLiteral value: String) {
        self.text = value
    }

    init(stringInterpolation: DefaultStringInterpolation) {
        self.text = stringInterpolation.description
    }

    var description: String { text }

    static func == (lhs: CatalogName, rhs: CatalogName) -> Bool {
        lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    func hash(into hasher: inout Hasher) {
        CatalogName.hash(text, into: &hasher)
    }

    static func < (lhs: CatalogName, rhs: CatalogName) -> Bool {
        if lhs.text != rhs.text { return lhs.text < rhs.text }
        return lhs.text.utf8.lexicographicallyPrecedes(rhs.text.utf8)
    }

    // A String equal to another one's exactly when their bytes are, for keys built by joining strings. An ASCII name
    // has no other spelling, so it stays as it is.
    var exactKey: String {
        text.utf8.allSatisfy { $0 < 0x80 } ? text : Self.bytesPrefix + text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    init?(exactKey key: String) {
        guard key.hasPrefix(Self.bytesPrefix) else { return nil }
        let hex = Array(key.utf8.dropFirst(Self.bytesPrefix.utf8.count))
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let high = Self.hexValue(hex[index]), let low = Self.hexValue(hex[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        self.text = text
    }

    private static func hexValue(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    private static let bytesPrefix = "\u{1}utf8:"

    static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }

    static func hash(_ name: String?, into hasher: inout Hasher) {
        guard let name else {
            hasher.combine(-1)
            return
        }
        hasher.combine(name.utf8.count)
        let hashed = name.utf8.withContiguousStorageIfAvailable { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        if hashed == nil {
            for byte in name.utf8 { hasher.combine(byte) }
        }
    }
}

extension Dictionary where Key == String {
    // A String-keyed answer holds each spelling once, so its keys stay distinct by bytes.
    var keyedByCatalogName: [CatalogName: Value] {
        [CatalogName: Value](uniqueKeysWithValues: map { (CatalogName($0.key), $0.value) })
    }
}

extension Dictionary where Key == CatalogName {
    subscript(catalogName name: String) -> Value? {
        self[CatalogName(name)]
    }
}

extension DatabaseScope {
    // A scope's own == leaves its names to String, which equates two schemas a server keeps apart.
    struct CatalogKey: Hashable, Sendable {
        let connectionId: UUID
        let database: CatalogName
        let schema: CatalogName?
    }

    var catalogKey: CatalogKey {
        CatalogKey(connectionId: connectionId, database: CatalogName(database), schema: schema.map { CatalogName($0) })
    }
}
