import CoreFoundation
import Foundation

public enum TabularTextEncoding: String, CaseIterable, Sendable, Codable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case windows1252
    case isoLatin1
    case shiftJIS
    case eucJP
    case gb18030
    case big5
    case eucKR

    public var readsInPlace: Bool {
        switch self {
        case .utf8, .windows1252, .isoLatin1:
            return true
        case .utf16LittleEndian, .utf16BigEndian, .shiftJIS, .eucJP, .gb18030, .big5, .eucKR:
            return false
        }
    }

    public var byteOrderMark: [UInt8] {
        switch self {
        case .utf8:
            return [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian:
            return [0xFF, 0xFE]
        case .utf16BigEndian:
            return [0xFE, 0xFF]
        case .windows1252, .isoLatin1, .shiftJIS, .eucJP, .gb18030, .big5, .eucKR:
            return []
        }
    }

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .windows1252: return "Windows-1252"
        case .isoLatin1: return "ISO Latin 1"
        case .shiftJIS: return "Shift JIS"
        case .eucJP: return "EUC-JP"
        case .gb18030: return "GB 18030"
        case .big5: return "Big5"
        case .eucKR: return "EUC-KR"
        }
    }

    public var foundationEncoding: String.Encoding {
        switch self {
        case .utf8:
            return .utf8
        case .utf16LittleEndian:
            return .utf16LittleEndian
        case .utf16BigEndian:
            return .utf16BigEndian
        case .windows1252:
            return .windowsCP1252
        case .isoLatin1:
            return .isoLatin1
        case .shiftJIS:
            return .shiftJIS
        case .eucJP:
            return .japaneseEUC
        case .gb18030:
            return Self.coreFoundationEncoding(CFStringEncodings.GB_18030_2000)
        case .big5:
            return Self.coreFoundationEncoding(CFStringEncodings.dosChineseTrad)
        case .eucKR:
            return Self.coreFoundationEncoding(CFStringEncodings.dosKorean)
        }
    }

    var codeUnitLayout: TabularCodeUnitLayout {
        switch self {
        case .utf16LittleEndian:
            return .utf16LittleEndian
        case .utf16BigEndian:
            return .utf16BigEndian
        case .utf8, .windows1252, .isoLatin1, .shiftJIS, .eucJP, .gb18030, .big5, .eucKR:
            return .asciiCompatible
        }
    }

    private static func coreFoundationEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        return String.Encoding(rawValue: raw)
    }
}
