//
//  ColumnTypeCorpusReaders.swift
//  ColumnTypeCorpus
//

import Foundation

// Read back independently of the writers, so a check never agrees with an export by sharing its code.
enum CorpusCSVReader {
    static func records(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if quoted {
                if character == "\"" {
                    if characters.first == "\"" {
                        field.append("\"")
                        characters = characters.dropFirst()
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                quoted = true
            case ",":
                record.append(field)
                field = ""
            case "\n", "\r\n":
                record.append(field)
                records.append(record)
                record = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}

indirect enum CorpusJSONValue: Equatable, Sendable {
    case object([(key: String, value: CorpusJSONValue)])
    case array([CorpusJSONValue])
    case string(String)
    // The literal as written, so a 78-digit integer is compared digit for digit.
    case number(String)
    case bool(Bool)
    case null

    static func == (lhs: CorpusJSONValue, rhs: CorpusJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let left), .object(let right)):
            left.map(\.key) == right.map(\.key) && left.map(\.value) == right.map(\.value)
        case (.array(let left), .array(let right)): left == right
        case (.string(let left), .string(let right)): left == right
        case (.number(let left), .number(let right)): left == right
        case (.bool(let left), .bool(let right)): left == right
        case (.null, .null): true
        default: false
        }
    }

    subscript(key: String) -> CorpusJSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }
}

struct CorpusJSONReader {
    struct Malformed: Error, CustomStringConvertible {
        let offset: Int
        var description: String { "malformed JSON at byte \(offset)" }
    }

    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ data: Data) throws -> CorpusJSONValue {
        var reader = CorpusJSONReader(bytes: Array(data))
        let value = try reader.value()
        reader.skipWhitespace()
        guard reader.index == reader.bytes.count else { throw Malformed(offset: reader.index) }
        return value
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func value() throws -> CorpusJSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw Malformed(offset: index) }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        default: return try number()
        }
    }

    private mutating func literal(_ word: String, _ value: CorpusJSONValue) throws -> CorpusJSONValue {
        let end = index + word.utf8.count
        guard end <= bytes.count, Array(bytes[index..<end]) == Array(word.utf8) else { throw Malformed(offset: index) }
        index = end
        return value
    }

    // RFC 8259: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?, so `+1`, `01` and `1.` are malformed, not numbers.
    private mutating func number() throws -> CorpusJSONValue {
        let start = index
        func digits() -> Int {
            let first = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            return index - first
        }
        func take(_ character: Character) -> Bool {
            guard index < bytes.count, bytes[index] == character.asciiValue else { return false }
            index += 1
            return true
        }
        _ = take("-")
        let leadingZero = index < bytes.count && bytes[index] == UInt8(ascii: "0")
        let whole = digits()
        guard whole > 0, !(leadingZero && whole > 1) else { throw Malformed(offset: start) }
        if take("."), digits() == 0 { throw Malformed(offset: start) }
        if take("e") || take("E") {
            if !take("+") { _ = take("-") }
            guard digits() > 0 else { throw Malformed(offset: start) }
        }
        guard let text = String(bytes: bytes[start..<index], encoding: .utf8) else { throw Malformed(offset: start) }
        return .number(text)
    }

    private mutating func object() throws -> CorpusJSONValue {
        index += 1
        var members: [(key: String, value: CorpusJSONValue)] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            let key = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Malformed(offset: index) }
            index += 1
            members.append((key, try value()))
            skipWhitespace()
            guard index < bytes.count else { throw Malformed(offset: index) }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            } else {
                throw Malformed(offset: index)
            }
        }
    }

    private mutating func array() throws -> CorpusJSONValue {
        index += 1
        var elements: [CorpusJSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            elements.append(try value())
            skipWhitespace()
            guard index < bytes.count else { throw Malformed(offset: index) }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            } else {
                throw Malformed(offset: index)
            }
        }
    }

    private mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Malformed(offset: index) }
        index += 1
        var scalars = String.UnicodeScalarView()
        var pendingHighSurrogate: UInt32?
        var run: [UInt8] = []

        func flushRun() throws {
            guard !run.isEmpty else { return }
            guard let text = String(bytes: run, encoding: .utf8) else { throw Malformed(offset: index) }
            scalars.append(contentsOf: text.unicodeScalars)
            run = []
        }

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") {
                try flushRun()
                return String(scalars)
            }
            guard byte == UInt8(ascii: "\\") else {
                // RFC 8259 has a control character in a string escaped, so a raw newline is a broken export.
                guard byte >= 0x20 else { throw Malformed(offset: index - 1) }
                run.append(byte)
                continue
            }
            try flushRun()
            guard index < bytes.count else { throw Malformed(offset: index) }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                guard index + 4 <= bytes.count,
                      let hex = String(bytes: bytes[index..<index + 4], encoding: .ascii),
                      let code = UInt32(hex, radix: 16) else { throw Malformed(offset: index) }
                index += 4
                if (0xD800...0xDBFF).contains(code) {
                    pendingHighSurrogate = code
                    continue
                }
                if (0xDC00...0xDFFF).contains(code), let high = pendingHighSurrogate {
                    pendingHighSurrogate = nil
                    let combined = 0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)
                    guard let scalar = Unicode.Scalar(combined) else { throw Malformed(offset: index) }
                    scalars.append(scalar)
                    continue
                }
                guard let scalar = Unicode.Scalar(code) else { throw Malformed(offset: index) }
                scalars.append(scalar)
            default:
                throw Malformed(offset: index)
            }
        }
        throw Malformed(offset: index)
    }
}
