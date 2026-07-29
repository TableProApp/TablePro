//
//  CSVImportOptions.swift
//  CSVImportPlugin
//

import Foundation
import TableProPluginKit

struct CSVImportOptions: Equatable, Codable {
    enum Delimiter: String, Codable, CaseIterable, Identifiable {
        case auto
        case comma
        case semicolon
        case tab
        case pipe

        var id: String { rawValue }

        var byte: UInt8? {
            switch self {
            case .auto: return nil
            case .comma: return 0x2C
            case .semicolon: return 0x3B
            case .tab: return 0x09
            case .pipe: return 0x7C
            }
        }
    }

    enum QuoteCharacter: String, Codable, CaseIterable, Identifiable {
        case doubleQuote
        case singleQuote

        var id: String { rawValue }

        var byte: UInt8 {
            switch self {
            case .doubleQuote: return 0x22
            case .singleQuote: return 0x27
            }
        }
    }

    enum TextEncoding: String, Codable, CaseIterable, Identifiable {
        case auto
        case utf8
        case isoLatin1
        case windowsCP1252

        var id: String { rawValue }

        var stringEncoding: String.Encoding? {
            switch self {
            case .auto: return nil
            case .utf8: return .utf8
            case .isoLatin1: return .isoLatin1
            case .windowsCP1252: return .windowsCP1252
            }
        }
    }

    var delimiter: Delimiter = .auto
    var quoteCharacter: QuoteCharacter = .doubleQuote
    var encoding: TextEncoding = .auto
    var hasHeaderRow: Bool = true
    var trimWhitespace: Bool = false
    var emptyAsNull: Bool = true
    var nullString: String = ""
    var errorHandling: ImportErrorHandling = .stopAndRollback
    var wrapInTransaction: Bool = true
    var deleteExistingRows: Bool = false

    var detectionSignature: String {
        [
            delimiter.rawValue,
            quoteCharacter.rawValue,
            encoding.rawValue,
            hasHeaderRow ? "h1" : "h0",
            trimWhitespace ? "t1" : "t0",
            emptyAsNull ? "n1" : "n0",
            nullString
        ].joined(separator: "|")
    }
}
