//
//  MongoDBBinarySubtypes.swift
//  MongoDBDriverPlugin
//

import CryptoKit
import Foundation
import TableProPluginKit

/// The BSON subtype of each binary value the grid was handed, found again by the value itself.
///
/// A grid cell carries binary data as bytes alone, and a write has to send the subtype back. A
/// column-wide answer is wrong twice over: one field can hold several subtypes, and the kinds a
/// driver remembers are overwritten by whichever result it built last, which may be another tab's.
/// Keying by the field and a digest of the bytes ties the subtype to the value the user copied or
/// edited, and a value seen with two subtypes answers nothing rather than a guess.
struct MongoDBBinarySubtypes: Sendable {
    private var subtypesByField: [String: [Data: Set<UInt8>]] = [:]
    private(set) var count = 0

    static let empty = MongoDBBinarySubtypes()

    var isEmpty: Bool { subtypesByField.isEmpty }

    /// Every top-level binary value in the documents, which is every value a cell can hold as bytes.
    static func recording(_ documents: [[String: Any]]) -> MongoDBBinarySubtypes {
        var recorded = MongoDBBinarySubtypes()
        for document in documents {
            for (field, value) in document {
                if let binary = value as? MongoDBBinaryValue {
                    recorded.record(binary.data, subtype: binary.subtype, field: field)
                } else if let data = value as? Data {
                    recorded.record(data, subtype: 0, field: field)
                }
            }
        }
        return recorded
    }

    mutating func record(_ data: Data, subtype: UInt8, field: String) {
        insert(subtype, digest: Self.digest(of: data), field: field)
    }

    /// Every subtype the value was seen with in this field: one is the answer, none or several are not.
    func subtypes(of data: Data, in field: String) -> Set<UInt8> {
        subtypesByField[field]?[Self.digest(of: data)] ?? []
    }

    func merging(_ other: MongoDBBinarySubtypes) -> MongoDBBinarySubtypes {
        var merged = self
        for (field, digests) in other.subtypesByField {
            for (digest, subtypes) in digests {
                subtypes.forEach { merged.insert($0, digest: digest, field: field) }
            }
        }
        return merged
    }

    private mutating func insert(_ subtype: UInt8, digest: Data, field: String) {
        guard subtypesByField[field, default: [:]][digest, default: []].insert(subtype).inserted else { return }
        count += 1
    }

    private static func digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
