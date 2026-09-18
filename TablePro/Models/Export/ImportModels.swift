//
//  ImportModels.swift
//  TablePro
//
//  Encoding options for SQL import.
//

import Foundation

// MARK: - Import Encoding Options

/// The text encodings the SQL import dialog offers, matching the list the CSV inspector already
/// offers in `CSVPropertyOptions.encodings`.
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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .latin1: return "Latin-1"
        case .windows1252: return "Windows-1252"
        case .ascii: return "ASCII"
        }
    }

    var encoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16: return .utf16
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .latin1: return .isoLatin1
        case .windows1252: return .windowsCP1252
        case .ascii: return .ascii
        }
    }
}
