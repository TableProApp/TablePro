//
//  PhpSerializeParser.swift
//  TablePro
//

import Foundation

internal indirect enum PhpValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case float(Double)
    case string(String)
    case array([PhpKeyValue])
    case object(className: String, properties: [PhpProperty])
    case serializable(className: String, rawPayload: String)
    case reference(id: Int)
    case unsupported(token: String)
    case depthExceeded
    case tooLarge

    static func == (lhs: PhpValue, rhs: PhpValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.float(let a), .float(let b)):
            if a.isNaN && b.isNaN { return true }
            return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let aName, let aProps), .object(let bName, let bProps)):
            return aName == bName && aProps == bProps
        case (.serializable(let aName, let aPayload), .serializable(let bName, let bPayload)):
            return aName == bName && aPayload == bPayload
        case (.reference(let a), .reference(let b)): return a == b
        case (.unsupported(let a), .unsupported(let b)): return a == b
        case (.depthExceeded, .depthExceeded): return true
        case (.tooLarge, .tooLarge): return true
        default: return false
        }
    }
}

internal struct PhpKeyValue: Equatable {
    let key: PhpValue
    let value: PhpValue
}

internal struct PhpProperty: Equatable {
    let name: String
    let visibility: PhpVisibility
    let value: PhpValue
}

internal enum PhpVisibility: Equatable {
    case publicVisibility
    case protectedVisibility
    case privateVisibility(className: String)
}

internal enum PhpSerializeParser {
    static let sizeCapBytes = 5_000_000
    static let depthCap = 256

    static func looksLikePhpSerialized(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard (value as NSString).length <= sizeCapBytes else { return false }
        guard let first = value.unicodeScalars.first else { return false }
        let validFirst: Set<Unicode.Scalar> = ["N", "b", "i", "d", "s", "S", "a", "O", "C", "o", "r", "R"]
        guard validFirst.contains(first) else { return false }
        let bytes = Array(value.utf8)
        guard bytes.count >= 2 else { return false }
        if bytes[0] == UInt8(ascii: "N") {
            return bytes[1] == UInt8(ascii: ";")
        }
        return bytes.count >= 3 && bytes[1] == UInt8(ascii: ":")
    }

    static func parse(_ value: String) -> PhpValue? {
        guard !value.isEmpty else { return nil }
        guard (value as NSString).length <= sizeCapBytes else { return nil }
        var cursor = Cursor(bytes: Array(value.utf8))
        guard let result = cursor.parseValue(depth: 0) else { return nil }
        return result
    }
}

private struct Cursor {
    let bytes: [UInt8]
    var index: Int = 0

    var isAtEnd: Bool { index >= bytes.count }

    mutating func parseValue(depth: Int) -> PhpValue? {
        guard depth <= PhpSerializeParser.depthCap else { return .depthExceeded }
        guard index < bytes.count else { return nil }
        let token = bytes[index]
        switch token {
        case UInt8(ascii: "N"): return parseNull()
        case UInt8(ascii: "b"): return parseBool()
        case UInt8(ascii: "i"): return parseInt()
        case UInt8(ascii: "d"): return parseFloat()
        case UInt8(ascii: "s"), UInt8(ascii: "S"): return parseString(token: token)
        case UInt8(ascii: "a"): return parseArray(depth: depth)
        case UInt8(ascii: "O"): return parseObject(depth: depth)
        case UInt8(ascii: "C"): return parseSerializable()
        case UInt8(ascii: "o"):
            return .unsupported(token: "o")
        case UInt8(ascii: "r"), UInt8(ascii: "R"): return parseReference()
        default: return nil
        }
    }

    private mutating func expect(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func parseNull() -> PhpValue? {
        index += 1
        guard expect(UInt8(ascii: ";")) else { return nil }
        return .null
    }

    private mutating func parseBool() -> PhpValue? {
        index += 1
        guard expect(UInt8(ascii: ":")), index < bytes.count else { return nil }
        let digit = bytes[index]
        guard digit == UInt8(ascii: "0") || digit == UInt8(ascii: "1") else { return nil }
        index += 1
        guard expect(UInt8(ascii: ";")) else { return nil }
        return .bool(digit == UInt8(ascii: "1"))
    }

    private mutating func parseInt() -> PhpValue? {
        index += 1
        guard expect(UInt8(ascii: ":")) else { return nil }
        guard let raw = readUntil(UInt8(ascii: ";")) else { return nil }
        guard let value = Int(raw) else { return nil }
        guard expect(UInt8(ascii: ";")) else { return nil }
        return .int(value)
    }

    private mutating func parseFloat() -> PhpValue? {
        index += 1
        guard expect(UInt8(ascii: ":")) else { return nil }
        guard let raw = readUntil(UInt8(ascii: ";")) else { return nil }
        guard expect(UInt8(ascii: ";")) else { return nil }
        switch raw {
        case "INF": return .float(.infinity)
        case "-INF": return .float(-.infinity)
        case "NAN": return .float(.nan)
        default:
            guard let value = Double(raw) else { return nil }
            return .float(value)
        }
    }

    private mutating func parseString(token: UInt8) -> PhpValue? {
        index += 1
        guard expect(UInt8(ascii: ":")) else { return nil }
        guard let lengthRaw = readUntil(UInt8(ascii: ":")) else { return nil }
        guard let length = Int(lengthRaw), length >= 0 else { return nil }
        guard expect(UInt8(ascii: ":")), expect(UInt8(ascii: "\"")) else { return nil }
        guard index + length <= bytes.count else { return nil }
        guard let decoded = String(bytes: bytes[index..<(index + length)], encoding: .utf8) else { return nil }
        index += length
        guard expect(UInt8(ascii: "\"")), expect(UInt8(ascii: ";")) else { return nil }
        return .string(decoded)
    }

    private mutating func parseArray(depth: Int) -> PhpValue? {
        index += 1
        guard expect(UInt8(ascii: ":")) else { return nil }
        guard let countRaw = readUntil(UInt8(ascii: ":")) else { return nil }
        guard let count = Int(countRaw), count >= 0 else { return nil }
        guard expect(UInt8(ascii: ":")), expect(UInt8(ascii: "{")) else { return nil }

        var entries: [PhpKeyValue] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard let key = parseValue(depth: depth + 1) else { return nil }
            guard let value = parseValue(depth: depth + 1) else { return nil }
            entries.append(PhpKeyValue(key: key, value: value))
        }
        guard expect(UInt8(ascii: "}")) else { return nil }
        return .array(entries)
    }

    private mutating func parseObject(depth: Int) -> PhpValue? {
        index += 1
        guard expect(UInt8(ascii: ":")) else { return nil }
        guard let nameLengthRaw = readUntil(UInt8(ascii: ":")) else { return nil }
        guard let nameLength = Int(nameLengthRaw), nameLength >= 0 else { return nil }
        guard expect(UInt8(ascii: ":")), expect(UInt8(ascii: "\"")) else { return nil }
        guard index + nameLength <= bytes.count else { return nil }
        guard let className = String(bytes: bytes[index..<(index + nameLength)], encoding: .utf8) else { return nil }
        index += nameLength
        guard expect(UInt8(ascii: "\"")), expect(UInt8(ascii: ":")) else { return nil }
        guard let countRaw = readUntil(UInt8(ascii: ":")) else { return nil }
        guard let count = Int(countRaw), count >= 0 else { return nil }
        guard expect(UInt8(ascii: ":")), expect(UInt8(ascii: "{")) else { return nil }

        var properties: [PhpProperty] = []
        properties.reserveCapacity(count)
        for _ in 0..<count {
            guard case let .string(rawKey)? = parseValue(depth: depth + 1) else { return nil }
            let decoded = decodePropertyKey(rawKey)
            guard let value = parseValue(depth: depth + 1) else { return nil }
            properties.append(PhpProperty(name: decoded.name, visibility: decoded.visibility, value: value))
        }
        guard expect(UInt8(ascii: "}")) else { return nil }
        return .object(className: className, properties: properties)
    }

    private mutating func parseSerializable() -> PhpValue? {
        index += 1
        guard expect(UInt8(ascii: ":")) else { return nil }
        guard let nameLengthRaw = readUntil(UInt8(ascii: ":")) else { return nil }
        guard let nameLength = Int(nameLengthRaw), nameLength >= 0 else { return nil }
        guard expect(UInt8(ascii: ":")), expect(UInt8(ascii: "\"")) else { return nil }
        guard index + nameLength <= bytes.count else { return nil }
        guard let className = String(bytes: bytes[index..<(index + nameLength)], encoding: .utf8) else { return nil }
        index += nameLength
        guard expect(UInt8(ascii: "\"")), expect(UInt8(ascii: ":")) else { return nil }
        guard let payloadLengthRaw = readUntil(UInt8(ascii: ":")) else { return nil }
        guard let payloadLength = Int(payloadLengthRaw), payloadLength >= 0 else { return nil }
        guard expect(UInt8(ascii: ":")), expect(UInt8(ascii: "{")) else { return nil }
        guard index + payloadLength <= bytes.count else { return nil }
        let payload = String(bytes: bytes[index..<(index + payloadLength)], encoding: .utf8) ?? ""
        index += payloadLength
        guard expect(UInt8(ascii: "}")) else { return nil }
        return .serializable(className: className, rawPayload: payload)
    }

    private mutating func parseReference() -> PhpValue? {
        index += 1
        guard expect(UInt8(ascii: ":")) else { return nil }
        guard let raw = readUntil(UInt8(ascii: ";")) else { return nil }
        guard let value = Int(raw) else { return nil }
        guard expect(UInt8(ascii: ";")) else { return nil }
        return .reference(id: value)
    }

    private mutating func readUntil(_ terminator: UInt8) -> String? {
        let start = index
        while index < bytes.count, bytes[index] != terminator {
            index += 1
        }
        guard index < bytes.count else { return nil }
        return String(bytes: bytes[start..<index], encoding: .utf8)
    }
}

private func decodePropertyKey(_ raw: String) -> (name: String, visibility: PhpVisibility) {
    let scalars = Array(raw.unicodeScalars)
    guard scalars.first?.value == 0 else {
        return (raw, .publicVisibility)
    }
    let secondNullIndex = scalars.dropFirst().firstIndex { $0.value == 0 }
    guard let nullIndex = secondNullIndex, nullIndex < scalars.count - 1 else {
        return (raw, .publicVisibility)
    }
    let middle = String(String.UnicodeScalarView(scalars[1..<nullIndex]))
    let nameScalars = scalars[(nullIndex + 1)...]
    let name = String(String.UnicodeScalarView(nameScalars))
    if middle == "*" {
        return (name, .protectedVisibility)
    }
    return (name, .privateVisibility(className: middle))
}
