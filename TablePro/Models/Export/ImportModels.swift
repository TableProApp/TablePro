//
//  ImportModels.swift
//  TablePro
//
//  Encoding options for SQL import.
//

import Foundation

// MARK: - Import Encoding Options

/// Available text encodings for import
enum ImportEncoding: String, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case utf16 = "UTF-16"
    case latin1 = "Latin1"
    case ascii = "ASCII"

    var id: String { rawValue }

    var encoding: String.Encoding {
        switch self {
        case .utf8:
            return .utf8
        case .utf16:
            return .utf16
        case .latin1:
            return .isoLatin1
        case .ascii:
            return .ascii
        }
    }
}
