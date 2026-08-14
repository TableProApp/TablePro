import Foundation

enum DamengStatementClassifier {
    private static let resultKeywords: Set<String> = [
        "DESC", "DESCRIBE", "EXPLAIN", "SELECT", "SHOW", "VALUES", "WITH"
    ]

    static func expectsRows(_ query: String) -> Bool {
        guard let keyword = firstKeyword(query) else { return false }
        return resultKeywords.contains(keyword)
    }

    static func applyingRowCap(_ rowCap: Int?, to query: String) -> String {
        guard let rowCap, rowCap > 0,
              let keyword = firstKeyword(query),
              keyword == "SELECT" || keyword == "WITH",
              let statement = singleStatement(query) else {
            return query
        }
        let serverCap = rowCap == Int.max ? rowCap : rowCap + 1
        return "SELECT * FROM (\n\(statement)\n) TABLEPRO_ROW_CAP WHERE ROWNUM <= \(serverCap)"
    }

    private static func firstKeyword(_ query: String) -> String? {
        let bytes = Array(query.utf8)
        var index = 0
        while index < bytes.count {
            if isWhitespace(bytes[index]) || bytes[index] == 0x28 || bytes[index] == 0x3B {
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index] == 0x2D, bytes[index + 1] == 0x2D {
                index = skipLineComment(bytes, from: index + 2)
                continue
            }
            if index + 1 < bytes.count, bytes[index] == 0x2F, bytes[index + 1] == 0x2A {
                index = skipBlockComment(bytes, from: index + 2)
                continue
            }
            let start = index
            while index < bytes.count, isKeywordByte(bytes[index]) {
                index += 1
            }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self).uppercased()
        }
        return nil
    }

    private static func singleStatement(_ query: String) -> String? {
        let bytes = Array(query.utf8)
        var state: UInt8 = 0
        var alternativeCloser: UInt8 = 0
        var blockDepth = 0
        var semicolonIndex: Int?
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil
            if state == 0 {
                if byte == 0x27 {
                    state = 1
                } else if byte == 0x22 {
                    state = 2
                } else if byte == 0x2D, next == 0x2D {
                    state = 3
                    index += 1
                } else if byte == 0x2F, next == 0x2A {
                    state = 4
                    blockDepth = 1
                    index += 1
                } else if isAlternativeQuoteStart(bytes, at: index) {
                    alternativeCloser = alternativeQuoteCloser(for: bytes[index + 2])
                    state = 5
                    index += 2
                } else if byte == 0x3B {
                    guard semicolonIndex == nil else { return nil }
                    semicolonIndex = index
                }
            } else if state == 1, byte == 0x27 {
                if next == 0x27 {
                    index += 1
                } else {
                    state = 0
                }
            } else if state == 2, byte == 0x22 {
                if next == 0x22 {
                    index += 1
                } else {
                    state = 0
                }
            } else if state == 3, (byte == 0x0A || byte == 0x0D) {
                state = 0
            } else if state == 4 {
                if byte == 0x2F, next == 0x2A {
                    blockDepth += 1
                    index += 1
                } else if byte == 0x2A, next == 0x2F {
                    blockDepth -= 1
                    index += 1
                    if blockDepth == 0 { state = 0 }
                }
            } else if state == 5, byte == alternativeCloser, next == 0x27 {
                state = 0
                index += 1
            }
            index += 1
        }

        let end: Int
        if let semicolonIndex {
            guard bytes.suffix(from: semicolonIndex + 1).allSatisfy(isWhitespace) else { return nil }
            end = semicolonIndex
        } else {
            end = bytes.count
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func skipLineComment(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
            index += 1
        }
        return index
    }

    private static func skipBlockComment(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        var depth = 1
        while index + 1 < bytes.count {
            if bytes[index] == 0x2F, bytes[index + 1] == 0x2A {
                depth += 1
                index += 2
            } else if bytes[index] == 0x2A, bytes[index + 1] == 0x2F {
                depth -= 1
                index += 2
                if depth == 0 { return index }
            } else {
                index += 1
            }
        }
        return bytes.count
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isKeywordByte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F
    }

    private static func isAlternativeQuoteStart(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 2 < bytes.count else { return false }
        return (bytes[index] == 0x51 || bytes[index] == 0x71) && bytes[index + 1] == 0x27
    }

    private static func alternativeQuoteCloser(for opener: UInt8) -> UInt8 {
        switch opener {
        case 0x5B: return 0x5D
        case 0x28: return 0x29
        case 0x7B: return 0x7D
        case 0x3C: return 0x3E
        default: return opener
        }
    }
}
