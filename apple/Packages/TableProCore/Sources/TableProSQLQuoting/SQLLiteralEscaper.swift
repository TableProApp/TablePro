// Works on UTF-8 bytes. Every byte an escape acts on is ASCII, and UTF-8 never puts an ASCII byte
// inside a longer sequence, so each byte found here is exactly a scalar the header rule in
// SQLQuoting.swift means. An export escapes every text cell, so a value with nothing to escape
// costs one scan and no copy.
enum SQLLiteralEscaper {
    static func literal(_ value: String, escapes: SQLStringEscapes, quoted: Bool) -> String {
        if escapes == .sqlServer {
            return sqlServerLiteral(value, quoted: quoted)
        }
        var text = value
        let escaped: String? = text.withUTF8 { bytes in
            escapedLiteral(bytes, escapes: escapes, quoted: quoted)
        }
        return escaped ?? text
    }

    // Nil when the bytes need no change and no quotes: the caller's own string is the answer.
    private static func escapedLiteral(
        _ bytes: UnsafeBufferPointer<UInt8>,
        escapes: SQLStringEscapes,
        quoted: Bool
    ) -> String? {
        let triggers = triggerTable(for: escapes)
        var growth = 0
        var hasTrigger = false
        triggers.withUnsafeBufferPointer { table in
            for index in bytes.indices where table[Int(bytes[index])] {
                hasTrigger = true
                growth += escapeLength(of: bytes, at: index, escapes: escapes) - 1
            }
        }
        guard hasTrigger || quoted else { return nil }
        let length = bytes.count + growth + (quoted ? 2 : 0)
        guard length > 0 else { return "" }
        return String(unsafeUninitializedCapacity: length) { output in
            var written = 0
            if quoted {
                output[written] = UInt8(ascii: "'")
                written += 1
            }
            triggers.withUnsafeBufferPointer { table in
                var runStart = 0
                for index in bytes.indices where table[Int(bytes[index])] {
                    written = copy(bytes, from: runStart, to: index, into: output, at: written)
                    written = writeEscape(of: bytes, at: index, escapes: escapes, into: output, at: written)
                    runStart = index + 1
                }
                written = copy(bytes, from: runStart, to: bytes.count, into: output, at: written)
            }
            if quoted {
                output[written] = UInt8(ascii: "'")
                written += 1
            }
            return written
        }
    }

    // Microsoft KB 164291 doubles both the backslash and CRLF. The engine also consumes
    // backslash-LF, but keeps a bare CR. NUL goes first, so adjacency is read without it.
    private static func sqlServerLiteral(_ value: String, quoted: Bool) -> String {
        var body = literal(value, escapes: .standard, quoted: false)
        let escaped: String? = body.withUTF8 { bytes in
            var growth = 0
            for index in bytes.indices where bytes[index] == backslash {
                growth += sqlServerInsertion(after: index, in: bytes).count
            }
            guard growth > 0 || quoted else { return nil }
            let length = bytes.count + growth + (quoted ? 2 : 0)
            guard length > 0 else { return "" }
            return String(unsafeUninitializedCapacity: length) { output in
                var written = 0
                if quoted {
                    output[written] = UInt8(ascii: "'")
                    written += 1
                }
                var runStart = 0
                for index in bytes.indices where bytes[index] == backslash {
                    let insertion = sqlServerInsertion(after: index, in: bytes)
                    guard !insertion.isEmpty else { continue }
                    written = copy(bytes, from: runStart, to: index + 1, into: output, at: written)
                    for byte in insertion {
                        output[written] = byte
                        written += 1
                    }
                    runStart = index + 1
                }
                written = copy(bytes, from: runStart, to: bytes.count, into: output, at: written)
                if quoted {
                    output[written] = UInt8(ascii: "'")
                    written += 1
                }
                return written
            }
        }
        return escaped ?? body
    }

    private static let backslash = UInt8(ascii: "\\")
    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let sqlServerLineFeedInsertion: [UInt8] = [backslash, lineFeed]
    private static let sqlServerCarriageReturnInsertion: [UInt8] = [backslash]
    private static let sqlServerCRLFInsertion: [UInt8] = [backslash, carriageReturn, lineFeed]

    // What follows the backslash at `index`, written after it, before the bytes that follow.
    private static func sqlServerInsertion(after index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        guard index + 1 < bytes.count else { return [] }
        if bytes[index + 1] == lineFeed {
            return sqlServerLineFeedInsertion
        }
        guard bytes[index + 1] == carriageReturn else { return [] }
        if index + 2 < bytes.count, bytes[index + 2] == lineFeed {
            return sqlServerCRLFInsertion
        }
        return sqlServerCarriageReturnInsertion
    }

    private static func copy(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int,
        into output: UnsafeMutableBufferPointer<UInt8>,
        at offset: Int
    ) -> Int {
        guard end > start, let source = bytes.baseAddress, let target = output.baseAddress else { return offset }
        (target + offset).update(from: source + start, count: end - start)
        return offset + end - start
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func nulBeforeDigit(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        index + 1 < bytes.count && isDigit(bytes[index + 1])
    }

    // The number of bytes the escape of the trigger byte at `index` writes.
    private static func escapeLength(
        of bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        escapes: SQLStringEscapes
    ) -> Int {
        let byte = bytes[index]
        switch escapes {
        case .standard, .sqlServer:
            return byte == 0 ? 0 : 2
        case .backslash:
            return byte == 0 && nulBeforeDigit(bytes, at: index) ? 4 : 2
        case .mysql:
            return 2
        case .googleSQL:
            switch byte {
            case backslash, UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: "`"), lineFeed, carriageReturn,
                 UInt8(ascii: "\t"):
                return 2
            default:
                return 4
            }
        }
    }

    private static func writeEscape(
        of bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        escapes: SQLStringEscapes,
        into output: UnsafeMutableBufferPointer<UInt8>,
        at offset: Int
    ) -> Int {
        let byte = bytes[index]
        var written = offset
        func put(_ escape: StaticString) {
            escape.withUTF8Buffer { escapeBytes in
                for escapeByte in escapeBytes {
                    output[written] = escapeByte
                    written += 1
                }
            }
        }
        switch (escapes, byte) {
        case (.standard, 0), (.sqlServer, 0):
            break
        case (.googleSQL, lineFeed):
            put(#"\n"#)
        case (.googleSQL, carriageReturn):
            put(#"\r"#)
        case (.googleSQL, UInt8(ascii: "\t")):
            put(#"\t"#)
        case (.googleSQL, backslash), (.googleSQL, UInt8(ascii: "'")), (.googleSQL, UInt8(ascii: "\"")),
             (.googleSQL, UInt8(ascii: "`")):
            output[written] = backslash
            output[written + 1] = byte
            written += 2
        case (.googleSQL, _):
            put(#"\x"#)
            output[written] = hexDigits[Int(byte >> 4)]
            output[written + 1] = hexDigits[Int(byte & 0xF)]
            written += 2
        case (_, UInt8(ascii: "'")):
            put("''")
        case (_, backslash):
            put(#"\\"#)
        case (.backslash, 0) where nulBeforeDigit(bytes, at: index):
            put(#"\x00"#)
        case (_, 0):
            put(#"\0"#)
        case (.mysql, 0x08):
            put(#"\b"#)
        case (.mysql, lineFeed):
            put(#"\n"#)
        case (.mysql, carriageReturn):
            put(#"\r"#)
        case (.mysql, UInt8(ascii: "\t")):
            put(#"\t"#)
        case (.mysql, 0x1A):
            put(#"\Z"#)
        default:
            output[written] = byte
            written += 1
        }
        return written
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static let standardTriggers = table { $0 == UInt8(ascii: "'") || $0 == 0 }
    private static let backslashTriggers = table { $0 == UInt8(ascii: "'") || $0 == 0 || $0 == backslash }
    private static let mysqlTriggers = table { byte in
        switch byte {
        case UInt8(ascii: "'"), 0, backslash, 0x08, lineFeed, carriageReturn, UInt8(ascii: "\t"), 0x1A: true
        default: false
        }
    }
    private static let googleSQLTriggers = table { byte in
        switch byte {
        case backslash, UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: "`"): true
        default: byte < 0x20 || byte == 0x7F
        }
    }

    private static func table(_ isTrigger: (UInt8) -> Bool) -> [Bool] {
        (0...255).map { isTrigger(UInt8($0)) }
    }

    private static func triggerTable(for escapes: SQLStringEscapes) -> [Bool] {
        switch escapes {
        case .standard, .sqlServer: standardTriggers
        case .backslash: backslashTriggers
        case .mysql: mysqlTriggers
        case .googleSQL: googleSQLTriggers
        }
    }
}
