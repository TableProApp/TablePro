import Foundation

/// The non-ASCII characters that end a word although no engine reads them as SQL: full-width punctuation, curly
/// quotes and non-ASCII spaces, which arrive by pasting from a word processor or typing with a CJK input method.
///
/// Every other non-ASCII character continues a word, which is how unquoted non-Latin identifiers stay whole.
public enum SQLSeparatingCharacter: Sendable, Equatable {
    case fullWidthPunctuation
    case curlyQuote
    case nonASCIISpace

    public static let fullWidthForms: ClosedRange<UInt16> = 0xFF01...0xFF5E

    public static func isFullWidthWordUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF3F, 0xFF41...0xFF5A:
            return true
        default:
            return false
        }
    }

    public static func kind(of unit: UInt16) -> SQLSeparatingCharacter? {
        switch unit {
        case fullWidthForms where !isFullWidthWordUnit(unit):
            return .fullWidthPunctuation
        case 0x2018, 0x2019, 0x201C, 0x201D:
            return .curlyQuote
        case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return .nonASCIISpace
        default:
            return nil
        }
    }

    public static func isSeparating(_ unit: UInt16) -> Bool {
        kind(of: unit) != nil
    }
}
