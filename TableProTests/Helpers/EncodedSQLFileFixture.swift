//
//  EncodedSQLFileFixture.swift
//  TableProTests
//

import Foundation

internal enum EncodedSQLFileFixture: String, CaseIterable, Sendable {
    case utf8
    case utf8WithByteOrderMark
    case utf16LittleEndianWithByteOrderMark
    case utf16BigEndianWithByteOrderMark
    case utf32LittleEndianWithByteOrderMark
    case utf32BigEndianWithByteOrderMark
    case shiftJISByAttribute
    case windowsCyrillicByAttribute
    case macRomanByAttribute
    case utf16ByAttributeWithoutByteOrderMark
    case latin1Fallback

    private static let attributeName = "com.apple.TextEncoding"
    private static let unicodeOriginal = "SELECT '\u{65E5}\u{672C} Caf\u{E9}';\n"
    private static let unicodeEdited = "SELECT '\u{65E5}\u{672C} Caf\u{E9} \u{1F600}';\n"

    var original: String {
        switch self {
        case .shiftJISByAttribute: return "SELECT '\u{65E5}\u{672C}';\n"
        case .windowsCyrillicByAttribute: return "SELECT '\u{0416}\u{0438}';\n"
        case .macRomanByAttribute: return "SELECT 'Caf\u{E9} \u{2022}';\n"
        case .latin1Fallback: return "SELECT 'Caf\u{E9}';\n"
        default: return Self.unicodeOriginal
        }
    }

    var edited: String {
        switch self {
        case .shiftJISByAttribute: return "SELECT '\u{65E5}\u{672C}\u{8A9E}';\n"
        case .windowsCyrillicByAttribute: return "SELECT '\u{0416}\u{0438}\u{0437}\u{043D}\u{044C}';\n"
        case .macRomanByAttribute: return "SELECT 'Caf\u{E9} \u{2022} \u{2206}';\n"
        case .latin1Fallback: return "SELECT 'Caf\u{E9} cr\u{E8}me';\n"
        default: return Self.unicodeEdited
        }
    }

    var reportedEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8WithByteOrderMark: return .utf8
        case .utf16LittleEndianWithByteOrderMark, .utf16BigEndianWithByteOrderMark: return .utf16
        case .utf32LittleEndianWithByteOrderMark, .utf32BigEndianWithByteOrderMark: return .utf32
        case .shiftJISByAttribute: return .shiftJIS
        case .windowsCyrillicByAttribute: return .windowsCP1251
        case .macRomanByAttribute: return .macOSRoman
        case .utf16ByAttributeWithoutByteOrderMark: return .utf16
        case .latin1Fallback: return .isoLatin1
        }
    }

    var attributeValue: String? {
        switch self {
        case .shiftJISByAttribute: return "cp932;1056"
        case .windowsCyrillicByAttribute: return "windows-1251;1282"
        case .macRomanByAttribute: return "MACINTOSH;0"
        case .utf16ByAttributeWithoutByteOrderMark: return "utf-16;256"
        default: return nil
        }
    }

    func bytes(of text: String) -> Data? {
        guard let body = text.data(using: bodyEncoding) else { return nil }
        return Data(byteOrderMark) + body
    }

    func write(_ text: String, to url: URL) throws {
        guard let bytes = bytes(of: text) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try bytes.write(to: url)
        guard let attributeValue else { return }
        let value = Array(attributeValue.utf8)
        guard setxattr(url.path, Self.attributeName, value, value.count, 0, 0) == 0 else {
            throw POSIXError(.EIO)
        }
    }

    static func attributeValue(of url: URL) -> String? {
        let size = getxattr(url.path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, attributeName, &value, size, 0, 0) == size else { return nil }
        return String(bytes: value, encoding: .utf8)
    }

    private var byteOrderMark: [UInt8] {
        switch self {
        case .utf8WithByteOrderMark: return [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndianWithByteOrderMark: return [0xFF, 0xFE]
        case .utf16BigEndianWithByteOrderMark: return [0xFE, 0xFF]
        case .utf32LittleEndianWithByteOrderMark: return [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BigEndianWithByteOrderMark: return [0x00, 0x00, 0xFE, 0xFF]
        default: return []
        }
    }

    private var bodyEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8WithByteOrderMark: return .utf8
        case .utf16LittleEndianWithByteOrderMark: return .utf16LittleEndian
        case .utf16BigEndianWithByteOrderMark, .utf16ByAttributeWithoutByteOrderMark: return .utf16BigEndian
        case .utf32LittleEndianWithByteOrderMark: return .utf32LittleEndian
        case .utf32BigEndianWithByteOrderMark: return .utf32BigEndian
        case .shiftJISByAttribute: return .shiftJIS
        case .windowsCyrillicByAttribute: return .windowsCP1251
        case .macRomanByAttribute: return .macOSRoman
        case .latin1Fallback: return .isoLatin1
        }
    }
}
