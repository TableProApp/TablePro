import CoreFoundation
import Foundation

public enum TabularTextEncoding: String, CaseIterable, Sendable, Codable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case windows1252
    case isoLatin1
    case shiftJIS
    case gb18030
    case big5
    case eucKR

    public var readsInPlace: Bool {
        switch self {
        case .utf8, .windows1252, .isoLatin1:
            return true
        case .utf16LittleEndian, .utf16BigEndian, .shiftJIS, .gb18030, .big5, .eucKR:
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
        case .windows1252, .isoLatin1, .shiftJIS, .gb18030, .big5, .eucKR:
            return []
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
        case .gb18030:
            return Self.coreFoundationEncoding(CFStringEncodings.GB_18030_2000)
        case .big5:
            return Self.coreFoundationEncoding(CFStringEncodings.big5)
        case .eucKR:
            return Self.coreFoundationEncoding(CFStringEncodings.EUC_KR)
        }
    }

    private static func coreFoundationEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        return String.Encoding(rawValue: raw)
    }
}
