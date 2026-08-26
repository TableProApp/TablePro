import Foundation

struct KafkaProtocolWriter {
    private(set) var bytes: [UInt8] = []

    init() {
        bytes.reserveCapacity(256)
    }

    var data: Data { Data(bytes) }
    var count: Int { bytes.count }

    mutating func int8(_ value: Int8) {
        bytes.append(UInt8(bitPattern: value))
    }

    mutating func uint8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func boolean(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    mutating func int16(_ value: Int16) {
        unsigned(UInt16(bitPattern: value))
    }

    mutating func int32(_ value: Int32) {
        unsigned(UInt32(bitPattern: value))
    }

    mutating func int64(_ value: Int64) {
        unsigned(UInt64(bitPattern: value))
    }

    mutating func uint32(_ value: UInt32) {
        unsigned(value)
    }

    mutating func uuid(_ value: KafkaUUID) {
        bytes.append(contentsOf: value.bytes)
    }

    mutating func raw(_ value: Data) {
        bytes.append(contentsOf: value)
    }

    mutating func raw(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    mutating func unsignedVarint(_ value: UInt32) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }

    mutating func unsignedVarlong(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }

    mutating func varint(_ value: Int32) {
        let zigzag = (UInt32(bitPattern: value) << 1) ^ UInt32(bitPattern: value >> 31)
        unsignedVarint(zigzag)
    }

    mutating func varlong(_ value: Int64) {
        let zigzag = (UInt64(bitPattern: value) << 1) ^ UInt64(bitPattern: value >> 63)
        unsignedVarlong(zigzag)
    }

    mutating func legacyString(_ value: String) {
        let encoded = Array(value.utf8)
        int16(Int16(encoded.count))
        bytes.append(contentsOf: encoded)
    }

    mutating func nullableLegacyString(_ value: String?) {
        guard let value else {
            int16(-1)
            return
        }
        legacyString(value)
    }

    mutating func compactString(_ value: String) {
        let encoded = Array(value.utf8)
        unsignedVarint(UInt32(encoded.count + 1))
        bytes.append(contentsOf: encoded)
    }

    /// Null is uvarint 0 and an empty string is uvarint 1. The legacy -1 form does not apply
    /// to compact encoding, and a broker that reads one keeps consuming and then hangs up.
    mutating func nullableCompactString(_ value: String?) {
        guard let value else {
            unsignedVarint(0)
            return
        }
        compactString(value)
    }

    mutating func nullableLegacyBytes(_ value: Data?) {
        guard let value else {
            int32(-1)
            return
        }
        int32(Int32(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func nullableCompactBytes(_ value: Data?) {
        guard let value else {
            unsignedVarint(0)
            return
        }
        unsignedVarint(UInt32(value.count + 1))
        bytes.append(contentsOf: value)
    }

    mutating func compactArrayCount(_ count: Int?) {
        guard let count else {
            unsignedVarint(0)
            return
        }
        unsignedVarint(UInt32(count + 1))
    }

    mutating func legacyArrayCount(_ count: Int?) {
        int32(Int32(count ?? -1))
    }

    mutating func array<T>(_ items: [T], compact: Bool, _ element: (inout KafkaProtocolWriter, T) -> Void) {
        if compact {
            compactArrayCount(items.count)
        } else {
            legacyArrayCount(items.count)
        }
        for item in items {
            element(&self, item)
        }
    }

    /// This client never sends a tagged field, so the buffer is always the empty marker. It
    /// is still mandatory: a flexible struct that omits it shifts everything after it.
    mutating func emptyTaggedFields() {
        unsignedVarint(0)
    }

    private mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
        let width = MemoryLayout<T>.size
        for index in stride(from: width - 1, through: 0, by: -1) {
            bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8)))
        }
    }
}
