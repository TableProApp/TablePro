import Foundation

public struct DelimitedDialect: Equatable, Sendable {
    public enum LineEnding: String, CaseIterable, Sendable {
        case lf
        case crlf
        case cr

        public var bytes: [UInt8] {
            switch self {
            case .lf: return [0x0A]
            case .crlf: return [0x0D, 0x0A]
            case .cr: return [0x0D]
            }
        }
    }

    public static let comma: UInt8 = 0x2C
    public static let tab: UInt8 = 0x09
    public static let semicolon: UInt8 = 0x3B
    public static let pipe: UInt8 = 0x7C
    public static let doubleQuote: UInt8 = 0x22
    public static let backslash: UInt8 = 0x5C

    public var delimiter: UInt8
    public var quote: UInt8
    public var escape: UInt8
    public var encoding: TabularTextEncoding
    public var lineEnding: LineEnding
    public var hasByteOrderMark: Bool
    public var hasHeaderRow: Bool

    public init(
        delimiter: UInt8 = DelimitedDialect.comma,
        quote: UInt8 = DelimitedDialect.doubleQuote,
        escape: UInt8? = nil,
        encoding: TabularTextEncoding = .utf8,
        lineEnding: LineEnding = .lf,
        hasByteOrderMark: Bool = false,
        hasHeaderRow: Bool = true
    ) {
        self.delimiter = delimiter
        self.quote = quote
        self.escape = escape ?? quote
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hasByteOrderMark = hasByteOrderMark
        self.hasHeaderRow = hasHeaderRow
    }

    public var escapesByDoubling: Bool { escape == quote }

    public static func defaultDelimiter(forFileExtension fileExtension: String) -> UInt8 {
        switch fileExtension.lowercased() {
        case "tsv", "tab":
            return tab
        case "psv":
            return pipe
        default:
            return comma
        }
    }
}
