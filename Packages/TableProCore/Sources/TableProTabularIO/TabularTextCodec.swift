import Foundation

public struct UnencodableCharacter: Error, Equatable, Sendable {
    public let character: Character
    public let encoding: TabularTextEncoding

    public init(character: Character, encoding: TabularTextEncoding) {
        self.character = character
        self.encoding = encoding
    }
}

public enum TabularTextCodec {
    private static let windows1252HighHalf: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178
    ]

    private static let windows1252Reverse: [UInt32: UInt8] = {
        var reverse: [UInt32: UInt8] = [:]
        for (offset, scalar) in windows1252HighHalf.enumerated() {
            reverse[scalar] = UInt8(0x80 + offset)
        }
        return reverse
    }()

    public static func scalar(forByte byte: UInt8, in encoding: TabularTextEncoding) -> UInt32 {
        guard byte >= 0x80 else { return UInt32(byte) }
        guard encoding == .windows1252, byte < 0xA0 else { return UInt32(byte) }
        return windows1252HighHalf[Int(byte) - 0x80]
    }

    public static func appendUTF8(
        of bytes: UnsafeBufferPointer<UInt8>,
        from encoding: TabularTextEncoding,
        into buffer: inout [UInt8]
    ) {
        guard encoding != .utf8 else {
            buffer.append(contentsOf: bytes)
            return
        }
        for byte in bytes {
            if byte < 0x80 {
                buffer.append(byte)
                continue
            }
            appendUTF8(scalar: scalar(forByte: byte, in: encoding), into: &buffer)
        }
    }

    public static func utf8String<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    public static func string(from bytes: UnsafeBufferPointer<UInt8>, encoding: TabularTextEncoding) -> String {
        guard !bytes.isEmpty else { return "" }
        guard encoding != .utf8 else { return TabularTextCodec.utf8String(bytes) }
        var utf8: [UInt8] = []
        utf8.reserveCapacity(bytes.count + bytes.count / 4)
        appendUTF8(of: bytes, from: encoding, into: &utf8)
        return TabularTextCodec.utf8String(utf8)
    }

    public static func isASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        for byte in bytes where byte >= 0x80 {
            return false
        }
        return true
    }

    public static func encode(_ string: String, as encoding: TabularTextEncoding) throws -> [UInt8] {
        switch encoding {
        case .utf8:
            return Array(string.utf8)
        case .windows1252, .isoLatin1:
            return try encodeSingleByte(string, as: encoding)
        case .utf16LittleEndian, .utf16BigEndian, .shiftJIS, .gb18030, .big5, .eucKR:
            return try encodeWithFoundation(string, as: encoding)
        }
    }

    private static func encodeSingleByte(_ string: String, as encoding: TabularTextEncoding) throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count)
        for character in string {
            for scalar in character.unicodeScalars {
                guard let byte = singleByte(for: scalar.value, in: encoding) else {
                    throw UnencodableCharacter(character: character, encoding: encoding)
                }
                bytes.append(byte)
            }
        }
        return bytes
    }

    private static func singleByte(for scalar: UInt32, in encoding: TabularTextEncoding) -> UInt8? {
        if scalar < 0x80 { return UInt8(scalar) }
        if encoding == .isoLatin1 { return scalar <= 0xFF ? UInt8(scalar) : nil }
        if let mapped = windows1252Reverse[scalar] { return mapped }
        if scalar >= 0xA0, scalar <= 0xFF { return UInt8(scalar) }
        return nil
    }

    private static func encodeWithFoundation(_ string: String, as encoding: TabularTextEncoding) throws -> [UInt8] {
        if let data = string.data(using: encoding.foundationEncoding, allowLossyConversion: false) {
            return [UInt8](data)
        }
        for character in string where String(character).data(
            using: encoding.foundationEncoding,
            allowLossyConversion: false
        ) == nil {
            throw UnencodableCharacter(character: character, encoding: encoding)
        }
        throw UnencodableCharacter(character: string.first ?? " ", encoding: encoding)
    }

    private static func appendUTF8(scalar: UInt32, into buffer: inout [UInt8]) {
        switch scalar {
        case ..<0x80:
            buffer.append(UInt8(scalar))
        case ..<0x800:
            buffer.append(UInt8(0xC0 | (scalar >> 6)))
            buffer.append(UInt8(0x80 | (scalar & 0x3F)))
        case ..<0x10000:
            buffer.append(UInt8(0xE0 | (scalar >> 12)))
            buffer.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            buffer.append(UInt8(0x80 | (scalar & 0x3F)))
        default:
            buffer.append(UInt8(0xF0 | (scalar >> 18)))
            buffer.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            buffer.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            buffer.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }
}
