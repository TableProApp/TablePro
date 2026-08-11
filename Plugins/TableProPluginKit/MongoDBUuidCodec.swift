import Foundation

public struct MongoDBBinaryValue: Sendable, Hashable {
    public let data: Data
    public let subtype: UInt8

    public init(data: Data, subtype: UInt8) {
        self.data = data
        self.subtype = subtype
    }
}

public enum MongoDBUuidRepresentation: String, Sendable, CaseIterable {
    case unspecified
    case javaLegacy
    case csharpLegacy
    case pythonLegacy

    public static func resolve(_ rawValue: String?) -> MongoDBUuidRepresentation {
        guard let rawValue, !rawValue.isEmpty else { return .unspecified }
        return MongoDBUuidRepresentation(rawValue: rawValue) ?? .unspecified
    }
}

public enum MongoDBUuidCodec {
    public static let uuidByteCount = 16
    public static let legacyUuidSubtype: UInt8 = 0x03
    public static let standardUuidSubtype: UInt8 = 0x04

    public static func decodedText(
        for binary: MongoDBBinaryValue,
        representation: MongoDBUuidRepresentation
    ) -> String? {
        guard let tag = wrapperTag(forSubtype: binary.subtype, representation: representation),
              let order = byteOrder(forSubtype: binary.subtype, representation: representation),
              binary.data.count == uuidByteCount,
              let uuid = uuidString(fromBytes: reorder([UInt8](binary.data), using: order)) else {
            return nil
        }
        return "\(tag)(\"\(uuid)\")"
    }

    public static func binaryText(for binary: MongoDBBinaryValue) -> String {
        "BinData(\(binary.subtype), \"\(binary.data.base64EncodedString())\")"
    }

    public static func columnTypeName(forSubtype subtype: UInt8) -> String {
        subtype == 0 ? binaryColumnTypeName : "\(binaryColumnTypeName)(\(subtype))"
    }

    public static func binarySubtype(fromColumnTypeName name: String) -> UInt8 {
        guard name.hasPrefix(binaryColumnTypeName + "("), name.hasSuffix(")") else { return 0 }
        let start = name.index(name.startIndex, offsetBy: binaryColumnTypeName.count + 1)
        let digits = name[start ..< name.index(before: name.endIndex)]
        return UInt8(digits) ?? 0
    }

    private static let binaryColumnTypeName = "BLOB"

    public static func isDecodableUuid(
        _ binary: MongoDBBinaryValue,
        representation: MongoDBUuidRepresentation
    ) -> Bool {
        binary.data.count == uuidByteCount
            && byteOrder(forSubtype: binary.subtype, representation: representation) != nil
    }

    public static func parseWrapper(_ text: String) -> MongoDBBinaryValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"),
              let openIndex = trimmed.firstIndex(of: "(") else {
            return nil
        }
        let tag = String(trimmed[trimmed.startIndex ..< openIndex])
        guard let wrapper = wrapperSpec(forTag: tag) else { return nil }

        let inner = trimmed[trimmed.index(after: openIndex) ..< trimmed.index(before: trimmed.endIndex)]
        guard let argument = unquote(String(inner).trimmingCharacters(in: .whitespaces)),
              let bytes = bytes(fromUuidString: argument) else {
            return nil
        }
        return MongoDBBinaryValue(
            data: Data(reorder(bytes, using: wrapper.order)),
            subtype: wrapper.subtype
        )
    }

    public static func extendedJson(for binary: MongoDBBinaryValue) -> String {
        let subtypeHex = String(format: "%02x", binary.subtype)
        let base64 = binary.data.base64EncodedString()
        return "{\"$binary\": {\"base64\": \"\(base64)\", \"subType\": \"\(subtypeHex)\"}}"
    }

    public static func extendedJsonFromWrapper(_ text: String) -> String? {
        parseWrapper(text).map { extendedJson(for: $0) }
    }

    // MARK: - Byte Order

    private enum ByteOrder {
        case identity
        case javaLegacy
        case csharpLegacy
    }

    private struct WrapperSpec {
        let subtype: UInt8
        let order: ByteOrder
    }

    private static func reorder(_ bytes: [UInt8], using order: ByteOrder) -> [UInt8] {
        guard bytes.count == uuidByteCount else { return bytes }
        switch order {
        case .identity:
            return bytes
        case .javaLegacy:
            return Array(bytes[0 ..< 8].reversed()) + Array(bytes[8 ..< 16].reversed())
        case .csharpLegacy:
            return Array(bytes[0 ..< 4].reversed())
                + Array(bytes[4 ..< 6].reversed())
                + Array(bytes[6 ..< 8].reversed())
                + Array(bytes[8 ..< 16])
        }
    }

    private static func byteOrder(
        forSubtype subtype: UInt8,
        representation: MongoDBUuidRepresentation
    ) -> ByteOrder? {
        if subtype == standardUuidSubtype { return .identity }
        guard subtype == legacyUuidSubtype else { return nil }
        switch representation {
        case .unspecified: return nil
        case .javaLegacy: return .javaLegacy
        case .csharpLegacy: return .csharpLegacy
        case .pythonLegacy: return .identity
        }
    }

    public static func wrapperTag(
        forSubtype subtype: UInt8,
        representation: MongoDBUuidRepresentation
    ) -> String? {
        if subtype == standardUuidSubtype { return "UUID" }
        guard subtype == legacyUuidSubtype else { return nil }
        switch representation {
        case .unspecified: return nil
        case .javaLegacy: return "LegacyJavaUUID"
        case .csharpLegacy: return "LegacyCSharpUUID"
        case .pythonLegacy: return "LegacyPythonUUID"
        }
    }

    private static func wrapperSpec(forTag tag: String) -> WrapperSpec? {
        switch tag {
        case "UUID":
            return WrapperSpec(subtype: standardUuidSubtype, order: .identity)
        case "LegacyJavaUUID", "JUUID":
            return WrapperSpec(subtype: legacyUuidSubtype, order: .javaLegacy)
        case "LegacyCSharpUUID", "CSUUID", "NUUID":
            return WrapperSpec(subtype: legacyUuidSubtype, order: .csharpLegacy)
        case "LegacyPythonUUID", "PYUUID", "LUUID":
            return WrapperSpec(subtype: legacyUuidSubtype, order: .identity)
        default:
            return nil
        }
    }

    // MARK: - UUID Text

    private static func unquote(_ value: String) -> String? {
        guard value.count >= 2, let first = value.first, let last = value.last else { return nil }
        guard first == last, first == "\"" || first == "'" else { return nil }
        return String(value.dropFirst().dropLast())
    }

    private static func bytes(fromUuidString value: String) -> [UInt8]? {
        var hex = ""
        hex.reserveCapacity(32)
        for character in value {
            if character == "-" || character == "{" || character == "}" { continue }
            guard character.isASCII, character.isHexDigit else { return nil }
            hex.append(character)
        }
        guard hex.count == 32 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(uuidByteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func uuidString(fromBytes bytes: [UInt8]) -> String? {
        guard bytes.count == uuidByteCount else { return nil }
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }
}
