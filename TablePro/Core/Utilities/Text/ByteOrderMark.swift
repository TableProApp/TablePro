//
//  ByteOrderMark.swift
//  TablePro
//

import Foundation

internal enum ByteOrderMark {
    case utf32LittleEndian
    case utf32BigEndian
    case utf16LittleEndian
    case utf16BigEndian

    private static let longestFirst: [ByteOrderMark] = [
        .utf32LittleEndian, .utf32BigEndian, .utf16LittleEndian, .utf16BigEndian
    ]

    static var longestLength: Int { longestFirst.map(\.length).max() ?? 0 }

    static func leading(_ bytes: Data) -> ByteOrderMark? {
        longestFirst.first { bytes.starts(with: $0.bytes) }
    }

    static func leading(_ bytes: Data, allowedBy declaredEncoding: String.Encoding) -> ByteOrderMark? {
        longestFirst.first { $0.isAllowed(by: declaredEncoding) && bytes.starts(with: $0.bytes) }
    }

    var bytes: [UInt8] {
        switch self {
        case .utf32LittleEndian: return [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BigEndian: return [0x00, 0x00, 0xFE, 0xFF]
        case .utf16LittleEndian: return [0xFF, 0xFE]
        case .utf16BigEndian: return [0xFE, 0xFF]
        }
    }

    var length: Int { bytes.count }

    var encoding: String.Encoding {
        switch self {
        case .utf32LittleEndian, .utf32BigEndian: return .utf32
        case .utf16LittleEndian, .utf16BigEndian: return .utf16
        }
    }

    var byteOrderedEncoding: String.Encoding {
        switch self {
        case .utf32LittleEndian: return .utf32LittleEndian
        case .utf32BigEndian: return .utf32BigEndian
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        }
    }

    var codeUnitLength: Int {
        switch self {
        case .utf32LittleEndian, .utf32BigEndian: return 4
        case .utf16LittleEndian, .utf16BigEndian: return 2
        }
    }

    private func isAllowed(by declaredEncoding: String.Encoding) -> Bool {
        declaredEncoding == encoding || declaredEncoding == byteOrderedEncoding
    }
}
