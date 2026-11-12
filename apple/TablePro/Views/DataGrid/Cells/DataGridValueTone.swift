//
//  DataGridValueTone.swift
//  TablePro
//

import Foundation

enum DataGridValueTone: Equatable, Sendable {
    case plain
    case string
    case number
    case dateTime
    case binary
    case json
    case uuid
    case enumeration

    // A `.text` column is whatever the classifier could not place, so only a character type's name makes it a string.
    static func base(of type: ColumnType?, declaresEnumLabels: Bool) -> DataGridValueTone {
        guard let type else { return .plain }
        switch type {
        case .integer, .decimal:
            return .number
        case .date, .timestamp, .datetime:
            return .dateTime
        case .blob:
            return .binary
        case .json:
            return .json
        case .enumType, .set:
            return .enumeration
        case .text(let rawType):
            if declaresEnumLabels { return .enumeration }
            if type.isUUIDType { return .uuid }
            guard let name = ColumnType.unwrappedTypeName(rawType), !name.isEmpty,
                  ColumnTypeSQLQuoting.isCharacterType(.text(rawType: name)) || isCharacterTypeName(name) else { return .plain }
            return .string
        case .boolean, .spatial, .vector, .array:
            return .plain
        }
    }

    // Character data `isCharacterType` leaves out: it also decides which columns a filter casts before LIKE.
    private static let characterTypeNames: Set<String> = [
        "KEYWORD", "WILDCARD", "CONSTANT_KEYWORD", "ASCII", "LONG", "SYSNAME",
    ]

    private static func isCharacterTypeName(_ name: String) -> Bool {
        characterTypeNames.contains(name.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces).uppercased())
    }

    static func shown(by format: ValueDisplayFormat) -> DataGridValueTone? {
        switch format {
        case .raw:
            return nil
        case .text:
            return .string
        case .uuid, .uuidSwappedTime:
            return .uuid
        case .unixTimestamp, .unixTimestampMillis:
            return .dateTime
        // Each shows a document as text: JSON, PHP serialize or protobuf text format.
        case .json, .phpSerialized, .messagePack, .protobuf, .igbinary, .avro, .protobufSchema, .schemaRegistry:
            return .json
        }
    }
}

struct DataGridColumnTone: Equatable, Sendable {
    static let plain = DataGridColumnTone(base: .plain, followsDisplayFormat: false)

    let base: DataGridValueTone
    let followsDisplayFormat: Bool

    private init(base: DataGridValueTone, followsDisplayFormat: Bool) {
        self.base = base
        self.followsDisplayFormat = followsDisplayFormat
    }

    init(columnType: ColumnType?, declaresEnumLabels: Bool) {
        self.init(base: DataGridValueTone.base(of: columnType, declaresEnumLabels: declaresEnumLabels), followsDisplayFormat: true)
    }

    // `isFormatted` comes from the formatter with the cached text: a value the format could not render reads as its column.
    func tone(displayedAs format: ValueDisplayFormat?, isFormatted: Bool) -> DataGridValueTone {
        guard followsDisplayFormat, isFormatted, let format, let shown = DataGridValueTone.shown(by: format) else {
            return base
        }
        return shown
    }
}
