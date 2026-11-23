//
//  PluginSQLQuoting.swift
//  TableProPluginKit
//

import Foundation

// TableProSQLQuoting's rules for the defaults every plugin inherits. The framework cannot link that package product:
// Xcode promotes a product a framework and its dependents share to a framework of its own, and refuses the static
// form. PluginSQLQuotingParityTests holds the two to the same output.
enum PluginSQLQuoting {
    enum Escapes {
        case standard
        case backslash
        case googleSQL

        init(features: SQLLexicalFeatures) {
            guard features.contains(.backslashEscapesInSingleQuotes) else {
                self = .standard
                return
            }
            self = features.contains(.tripleQuotedStrings) ? .googleSQL : .backslash
        }
    }

    static func identifier(_ name: String) -> String {
        var quoted = String.UnicodeScalarView()
        quoted.append("\"")
        for scalar in name.unicodeScalars {
            if scalar == "\"" { quoted.append(scalar) }
            quoted.append(scalar)
        }
        quoted.append("\"")
        return String(quoted)
    }

    static func stringLiteral(_ value: String, escapes: Escapes = .standard) -> String {
        literal(value, escapes: escapes, quoted: true)
    }

    static func stringLiteralBody(_ value: String, escapes: Escapes = .standard) -> String {
        literal(value, escapes: escapes, quoted: false)
    }

    static func likePattern(_ value: String) -> String {
        var pattern = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == "%" || scalar == "_" { pattern.append("\\") }
            pattern.append(scalar)
        }
        return String(pattern)
    }

    static func lineCommentText(_ text: String) -> String {
        var line = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}":
                line.append(" ")
            default:
                line.append(scalar)
            }
        }
        return String(line)
    }

    // On UTF-8 bytes, as TableProSQLQuoting's SQLLiteralEscaper: every byte an escape acts on is ASCII, and UTF-8
    // never puts an ASCII byte inside a longer sequence. A value with nothing to escape costs one scan and no copy.
    private static func literal(_ value: String, escapes: Escapes, quoted: Bool) -> String {
        var text = value
        let escaped: String? = text.withUTF8 { bytes in
            let triggers = triggerTable(for: escapes)
            var growth = 0
            var hasTrigger = false
            triggers.withUnsafeBufferPointer { table in
                for index in bytes.indices where table[Int(bytes[index])] {
                    hasTrigger = true
                    growth += escape(of: bytes, at: index, escapes: escapes).count - 1
                }
            }
            guard hasTrigger || quoted else { return nil }
            let length = bytes.count + growth + (quoted ? 2 : 0)
            guard length > 0 else { return "" }
            return String(unsafeUninitializedCapacity: length) { output in
                var written = 0
                func put<Bytes: Sequence>(_ run: Bytes) where Bytes.Element == UInt8 {
                    for byte in run {
                        output[written] = byte
                        written += 1
                    }
                }
                if quoted { put(CollectionOfOne(UInt8(ascii: "'"))) }
                triggers.withUnsafeBufferPointer { table in
                    var runStart = 0
                    for index in bytes.indices where table[Int(bytes[index])] {
                        put(UnsafeBufferPointer(rebasing: bytes[runStart..<index]))
                        put(escape(of: bytes, at: index, escapes: escapes))
                        runStart = index + 1
                    }
                    put(UnsafeBufferPointer(rebasing: bytes[runStart...]))
                }
                if quoted { put(CollectionOfOne(UInt8(ascii: "'"))) }
                return written
            }
        }
        return escaped ?? text
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static func escape(of bytes: UnsafeBufferPointer<UInt8>, at index: Int, escapes: Escapes) -> [UInt8] {
        let byte = bytes[index]
        switch (escapes, byte) {
        case (.googleSQL, UInt8(ascii: "\\")), (.googleSQL, UInt8(ascii: "'")), (.googleSQL, UInt8(ascii: "\"")),
             (.googleSQL, UInt8(ascii: "`")):
            return [UInt8(ascii: "\\"), byte]
        case (.googleSQL, UInt8(ascii: "\n")):
            return Array(#"\n"#.utf8)
        case (.googleSQL, UInt8(ascii: "\r")):
            return Array(#"\r"#.utf8)
        case (.googleSQL, UInt8(ascii: "\t")):
            return Array(#"\t"#.utf8)
        case (.googleSQL, _):
            return Array(#"\x"#.utf8) + [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0xF)]]
        case (_, UInt8(ascii: "'")):
            return Array("''".utf8)
        case (.standard, 0):
            return []
        case (_, UInt8(ascii: "\\")):
            return Array(#"\\"#.utf8)
        case (_, 0) where index + 1 < bytes.count && bytes[index + 1] >= UInt8(ascii: "0")
            && bytes[index + 1] <= UInt8(ascii: "9"):
            return Array(#"\x00"#.utf8)
        case (_, 0):
            return Array(#"\0"#.utf8)
        default:
            return [byte]
        }
    }

    private static let standardTriggers = table { $0 == UInt8(ascii: "'") || $0 == 0 }
    private static let backslashTriggers = table { $0 == UInt8(ascii: "'") || $0 == 0 || $0 == UInt8(ascii: "\\") }
    private static let googleSQLTriggers = table { byte in
        switch byte {
        case UInt8(ascii: "\\"), UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: "`"): true
        default: byte < 0x20 || byte == 0x7F
        }
    }

    private static func table(_ isTrigger: (UInt8) -> Bool) -> [Bool] {
        (0...255).map { isTrigger(UInt8($0)) }
    }

    private static func triggerTable(for escapes: Escapes) -> [Bool] {
        switch escapes {
        case .standard: standardTriggers
        case .backslash: backslashTriggers
        case .googleSQL: googleSQLTriggers
        }
    }
}
