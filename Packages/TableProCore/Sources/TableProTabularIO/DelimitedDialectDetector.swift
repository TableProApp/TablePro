import Foundation

public enum DelimitedDialectDetector {
    public struct EncodingSniff: Equatable, Sendable {
        public let encoding: TabularTextEncoding
        public let byteOrderMarkLength: Int

        public var hasByteOrderMark: Bool { byteOrderMarkLength > 0 }
    }

    public static let layoutScanLimit = 65_536
    public static let encodingScanLimit = 262_144

    private static let candidateDelimiters: [UInt8] = [
        DelimitedDialect.comma, DelimitedDialect.tab, DelimitedDialect.semicolon, DelimitedDialect.pipe
    ]

    public static func sniffEncoding(_ prefix: UnsafeBufferPointer<UInt8>) -> EncodingSniff {
        if hasPrefix(prefix, [0xEF, 0xBB, 0xBF]) {
            return EncodingSniff(encoding: .utf8, byteOrderMarkLength: 3)
        }
        if hasPrefix(prefix, [0xFF, 0xFE]) {
            return EncodingSniff(encoding: .utf16LittleEndian, byteOrderMarkLength: 2)
        }
        if hasPrefix(prefix, [0xFE, 0xFF]) {
            return EncodingSniff(encoding: .utf16BigEndian, byteOrderMarkLength: 2)
        }
        let probe = UnsafeBufferPointer(rebasing: prefix[0..<min(prefix.count, encodingScanLimit)])
        return EncodingSniff(encoding: isValidUTF8Prefix(probe) ? .utf8 : .windows1252, byteOrderMarkLength: 0)
    }

    public static func detect(
        _ bytes: UnsafeBufferPointer<UInt8>,
        contentStart: Int,
        encoding: TabularTextEncoding,
        hasByteOrderMark: Bool,
        fileExtension: String
    ) -> DelimitedDialect {
        let start = min(contentStart, bytes.count)
        let sample = UnsafeBufferPointer(rebasing: bytes[start..<min(bytes.count, start + layoutScanLimit)])
        let fallback = DelimitedDialect.defaultDelimiter(forFileExtension: fileExtension)
        let delimiter = forcedDelimiter(forFileExtension: fileExtension) ?? detectDelimiter(sample, fallback: fallback)
        var dialect = DelimitedDialect(
            delimiter: delimiter,
            encoding: encoding,
            lineEnding: detectLineEnding(sample),
            hasByteOrderMark: hasByteOrderMark,
            hasHeaderRow: false
        )
        dialect.hasHeaderRow = firstRowLooksLikeHeader(sample, dialect: dialect)
        return dialect
    }

    public static func firstRowLooksLikeHeader(_ sample: UnsafeBufferPointer<UInt8>, dialect: DelimitedDialect) -> Bool {
        guard let base = sample.baseAddress, !sample.isEmpty else { return false }
        let reader = DelimitedFieldReader(dialect: dialect)
        var scratch: [UInt8] = []
        var total = 0
        var textual = 0
        reader.forEachField(in: base, range: 0..<sample.count, scratch: &scratch) { _, content in
            total += 1
            if !content.isEmpty, TabularNumberGrammar.shape(of: content) == nil {
                textual += 1
            }
            return true
        }
        guard total > 0 else { return false }
        return textual * 2 >= total
    }

    private static func forcedDelimiter(forFileExtension fileExtension: String) -> UInt8? {
        switch fileExtension.lowercased() {
        case "tsv", "tab":
            return DelimitedDialect.tab
        case "psv":
            return DelimitedDialect.pipe
        default:
            return nil
        }
    }

    private static func detectDelimiter(_ bytes: UnsafeBufferPointer<UInt8>, fallback: UInt8) -> UInt8 {
        var counts = [Int](repeating: 0, count: candidateDelimiters.count)
        var insideQuotes = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == DelimitedDialect.doubleQuote {
                if insideQuotes, index + 1 < bytes.count, bytes[index + 1] == DelimitedDialect.doubleQuote {
                    index += 2
                    continue
                }
                insideQuotes.toggle()
                index += 1
                continue
            }
            if !insideQuotes, let slot = candidateDelimiters.firstIndex(of: byte) {
                counts[slot] += 1
            }
            index += 1
        }
        guard let best = counts.max(), best > 0 else { return fallback }
        if let fallbackSlot = candidateDelimiters.firstIndex(of: fallback), counts[fallbackSlot] == best {
            return fallback
        }
        guard let slot = counts.firstIndex(of: best) else { return fallback }
        return candidateDelimiters[slot]
    }

    private static func detectLineEnding(_ bytes: UnsafeBufferPointer<UInt8>) -> DelimitedDialect.LineEnding {
        var insideQuotes = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == DelimitedDialect.doubleQuote {
                insideQuotes.toggle()
                index += 1
                continue
            }
            if !insideQuotes {
                if byte == 0x0D {
                    return index + 1 < bytes.count && bytes[index + 1] == 0x0A ? .crlf : .cr
                }
                if byte == 0x0A {
                    return .lf
                }
            }
            index += 1
        }
        return .lf
    }

    private static func hasPrefix(_ bytes: UnsafeBufferPointer<UInt8>, _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        for (offset, byte) in prefix.enumerated() where bytes[offset] != byte {
            return false
        }
        return true
    }

    private static func isValidUTF8Prefix(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var end = bytes.count
        var continuation = 0
        while end > 0, continuation < 3, (bytes[end - 1] & 0xC0) == 0x80 {
            end -= 1
            continuation += 1
        }
        if end > 0, bytes[end - 1] >= 0xC0 {
            end -= 1
        }
        let trimmed = UnsafeBufferPointer(rebasing: bytes[0..<end])
        var iterator = trimmed.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue:
                continue
            case .emptyInput:
                return true
            case .error:
                return false
            }
        }
    }
}
