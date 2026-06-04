import Foundation

public struct CSVDialect: Equatable, Sendable {
    public enum LineEnding: Equatable, Sendable {
        case crlf
        case lf
        case cr

        public var bytes: [UInt8] {
            switch self {
            case .crlf: return [0x0D, 0x0A]
            case .lf:   return [0x0A]
            case .cr:   return [0x0D]
            }
        }
    }

    public var delimiter: UInt8
    public var quoteChar: UInt8
    public var encoding: String.Encoding
    public var lineEnding: LineEnding
    public var hasBom: Bool

    public init(
        delimiter: UInt8,
        quoteChar: UInt8 = 0x22,
        encoding: String.Encoding = .utf8,
        lineEnding: LineEnding = .lf,
        hasBom: Bool = false
    ) {
        self.delimiter = delimiter
        self.quoteChar = quoteChar
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hasBom = hasBom
    }

    public static let csv = CSVDialect(delimiter: 0x2C)
    public static let tsv = CSVDialect(delimiter: 0x09)

    private static let detectionScanLimit = 65_536

    public static func detect(from data: Data) -> CSVDialect {
        var hasBom = false
        var encoding: String.Encoding = .utf8
        var bomLength = 0
        let start = data.startIndex

        if data.count >= 3,
           data[start] == 0xEF, data[start + 1] == 0xBB, data[start + 2] == 0xBF {
            hasBom = true
            encoding = .utf8
            bomLength = 3
        } else if data.count >= 2, data[start] == 0xFE, data[start + 1] == 0xFF {
            hasBom = true
            encoding = .utf16BigEndian
            bomLength = 2
        } else if data.count >= 2, data[start] == 0xFF, data[start + 1] == 0xFE {
            hasBom = true
            encoding = .utf16LittleEndian
            bomLength = 2
        }

        let body = data.dropFirst(bomLength)
        if !hasBom {
            encoding = probeEncoding(body)
        }

        let sample = Array(body.prefix(detectionScanLimit))
        let delimiter = detectDelimiter(sample)
        let lineEnding = detectLineEnding(sample)

        return CSVDialect(
            delimiter: delimiter,
            encoding: encoding,
            lineEnding: lineEnding,
            hasBom: hasBom
        )
    }

    private static func probeEncoding(_ body: Data) -> String.Encoding {
        var probe = body.prefix(262_144)
        while let last = probe.last, (last & 0xC0) == 0x80 {
            probe = probe.dropLast()
        }
        if let last = probe.last, last >= 0xC0 {
            probe = probe.dropLast()
        }
        if String(data: Data(probe), encoding: .utf8) != nil {
            return .utf8
        }
        return .windowsCP1252
    }

    private static func detectDelimiter(_ bytes: [UInt8]) -> UInt8 {
        var counts: [UInt8: Int] = [0x2C: 0, 0x09: 0, 0x3B: 0, 0x7C: 0]
        var insideQuotes = false
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x22 {
                if insideQuotes, i + 1 < bytes.count, bytes[i + 1] == 0x22 {
                    i += 2
                    continue
                }
                insideQuotes.toggle()
                i += 1
                continue
            }
            if !insideQuotes, counts[byte] != nil {
                counts[byte, default: 0] += 1
            }
            i += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? 0x2C
    }

    private static func detectLineEnding(_ bytes: [UInt8]) -> LineEnding {
        var insideQuotes = false
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x22 {
                if insideQuotes, i + 1 < bytes.count, bytes[i + 1] == 0x22 {
                    i += 2
                    continue
                }
                insideQuotes.toggle()
                i += 1
                continue
            }
            if !insideQuotes {
                if byte == 0x0D {
                    return (i + 1 < bytes.count && bytes[i + 1] == 0x0A) ? .crlf : .cr
                }
                if byte == 0x0A {
                    return .lf
                }
            }
            i += 1
        }
        return .lf
    }

    public var bomBytes: [UInt8] {
        guard hasBom else { return [] }
        switch encoding {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .utf16BigEndian: return [0xFE, 0xFF]
        case .utf16LittleEndian: return [0xFF, 0xFE]
        default: return []
        }
    }
}
