//
//  UUIDCellForm.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// How a column holds a UUID, and so how a generated one is written into it.
///
/// A column typed as a UUID takes the canonical lowercase text, which every engine parses and the
/// ones that store text (SQLite, a MySQL `CHAR(36)`) keep as given. A column only the `.uuid`
/// display format marks takes the shape it was declared with: 32 hex digits for a `CHAR(32)`,
/// 16 bytes for a `BINARY(16)` or `RAW(16)`, which reject the 36-character text.
enum UUIDCellForm: Equatable, Sendable {
    case hyphenated
    case compact
    case bytes
    // Written in the order the column shows, so the UUID read back is the one written.
    case swappedTimeBytes

    /// Nil for a column that does not hold UUIDs, and for `timeuuid`, which takes only version 1.
    ///
    /// A MySQL result types a `CHAR(32)` as `CHAR` with no length. The length then comes from `declaredType`, the
    /// schema's spelling, and with no schema from `sampleText`, a value the column already holds.
    init?(
        columnType: ColumnType?,
        displayFormat: ValueDisplayFormat?,
        sampleText: String? = nil,
        declaredType: String? = nil
    ) {
        guard let columnType, !columnType.isTimeUUIDType else { return nil }
        if columnType.isUUIDType {
            self = .hyphenated
            return
        }
        if displayFormat == .uuidSwappedTime {
            guard columnType.isBlobType else { return nil }
            self = .swappedTimeBytes
            return
        }
        guard displayFormat == .uuid else { return nil }
        switch columnType {
        case .blob:
            self = .bytes
        case .text(let rawType):
            let length = Self.declaredLength(rawType) ?? Self.declaredLength(declaredType)
            if length == 32 {
                self = .compact
            } else if length == nil, Self.isCompactHex(sampleText) {
                self = .compact
            } else {
                self = .hyphenated
            }
        default:
            return nil
        }
    }

    func value(for uuid: UUID) -> PluginCellValue {
        switch self {
        case .hyphenated:
            return .text(uuid.uuidString.lowercased())
        case .compact:
            return .text(uuid.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
        case .bytes:
            return .bytes(withUnsafeBytes(of: uuid.uuid) { Data($0) })
        case .swappedTimeBytes:
            let bytes = withUnsafeBytes(of: uuid.uuid) { [UInt8]($0) }
            return .bytes(Data(UUIDByteOrder.swappedTime.storedBytes(fromUUID: bytes)))
        }
    }

    /// The number in `CHAR(32)` or `Nullable(FixedString(32))`.
    private static func declaredLength(_ rawType: String?) -> Int? {
        guard let rawType,
              let range = rawType.range(of: #"\(\s*\d+\s*\)"#, options: .regularExpression) else { return nil }
        return Int(rawType[range].filter(\.isNumber))
    }

    private static func isCompactHex(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.utf8.count == 32 else { return false }
        return text.allSatisfy(\.isHexDigit)
    }
}
