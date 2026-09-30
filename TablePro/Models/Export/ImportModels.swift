//
//  ImportModels.swift
//  TablePro
//
//  Encoding options for SQL import.
//

import Foundation
import TableProTabularIO

// MARK: - Import Encoding Options

/// The text encodings the SQL import dialog offers.
///
/// The raw value is the key the last choice is stored under, so it stays put; `label` is what the
/// menu shows. Latin-1 and Windows-1252 are both here because they disagree over 0x80 to 0x9F,
/// which is where a dump written by MySQL keeps its curly quotes, en dashes and euro sign: read
/// as Latin-1 they arrive as C1 control characters instead.
enum ImportEncoding: String, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case utf16 = "UTF-16"
    case utf16LittleEndian = "UTF-16LE"
    case utf16BigEndian = "UTF-16BE"
    case latin1 = "Latin1"
    case windows1252 = "Windows-1252"
    case ascii = "ASCII"
    case shiftJIS = "Shift_JIS"
    case eucJP = "EUC-JP"
    case gb18030 = "GB18030"
    case big5 = "Big5"
    case eucKR = "EUC-KR"

    var id: String { rawValue }

    init?(detected: TabularTextEncoding) {
        guard let match = Self.allCases.first(where: { $0.tabularEncoding == detected }) else { return nil }
        self = match
    }

    var canHideABackslashInsideACharacter: Bool {
        switch self {
        case .shiftJIS, .gb18030, .big5:
            return true
        case .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .latin1, .windows1252, .ascii, .eucJP, .eucKR:
            return false
        }
    }

    var label: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .latin1: return "Latin-1"
        case .windows1252: return "Windows-1252"
        case .ascii: return "ASCII"
        case .shiftJIS, .eucJP, .gb18030, .big5, .eucKR:
            return tabularEncoding?.displayName ?? rawValue
        }
    }

    var encoding: String.Encoding {
        switch self {
        case .utf16: return .utf16
        case .ascii: return .ascii
        case .utf8, .utf16LittleEndian, .utf16BigEndian, .latin1, .windows1252, .shiftJIS, .eucJP, .gb18030, .big5, .eucKR:
            return tabularEncoding?.foundationEncoding ?? .utf8
        }
    }

    private var tabularEncoding: TabularTextEncoding? {
        switch self {
        case .utf8: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .latin1: return .isoLatin1
        case .windows1252: return .windows1252
        case .shiftJIS: return .shiftJIS
        case .eucJP: return .eucJP
        case .gb18030: return .gb18030
        case .big5: return .big5
        case .eucKR: return .eucKR
        case .utf16, .ascii: return nil
        }
    }
}
