//
//  RowGenerationModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum RowGeneratorKind: String, Codable, CaseIterable, Sendable {
    case serverDefault
    case reference
    case sequence
    case integerRange
    case decimalRange
    case text
    case firstName
    case lastName
    case fullName
    case email
    case phone
    case streetAddress
    case city
    case country
    case date
    case dateTime
    case time
    case uuid
    case boolean
    case list
    case pattern
    case json

    internal var title: String {
        switch self {
        case .serverDefault: String(localized: "Server Default")
        case .reference: String(localized: "Referenced Value")
        case .sequence: String(localized: "Sequence")
        case .integerRange: String(localized: "Number Range")
        case .decimalRange: String(localized: "Decimal Range")
        case .text: String(localized: "Text")
        case .firstName: String(localized: "First Name")
        case .lastName: String(localized: "Last Name")
        case .fullName: String(localized: "Full Name")
        case .email: String(localized: "Email")
        case .phone: String(localized: "Phone Number")
        case .streetAddress: String(localized: "Street Address")
        case .city: String(localized: "City")
        case .country: String(localized: "Country")
        case .date: String(localized: "Date")
        case .dateTime: String(localized: "Date and Time")
        case .time: String(localized: "Time")
        case .uuid: "UUID"
        case .boolean: String(localized: "Boolean")
        case .list: String(localized: "List of Values")
        case .pattern: String(localized: "Pattern")
        case .json: "JSON"
        }
    }

    // Values made from words or names take a numbered suffix once random draws stop finding a new one.
    internal var takesDisambiguatingSuffix: Bool {
        switch self {
        case .text, .firstName, .lastName, .fullName, .email, .streetAddress, .city, .country:
            return true
        default:
            return false
        }
    }
}

// What a column can hold, read from its declared type.
internal enum RowGenerationValueClass: Equatable, Sendable {
    case integer(minimum: Int64, maximum: Int64)
    case decimal(precision: Int?, scale: Int?)
    case floatingPoint
    case text(maxLength: Int?)
    case date
    case time
    case timestamp
    case boolean
    case uuid
    case json
    case enumeration([String])
    case unsupported
}

internal enum RowGenerationServerOwnership: Equatable, Sendable {
    case none
    // Identity BY DEFAULT, a sequence default, a rowid alias: the server fills it when the INSERT leaves it out.
    case assigned
    // Generated, or identity ALWAYS: the server refuses any value for it.
    case computed
}

internal struct RowGenerationReferenceSlot: Equatable, Sendable {
    internal let sourceId: String
    internal let position: Int
}

internal struct RowGenerationColumn: Identifiable, Equatable, Sendable {
    internal let name: String
    internal let typeName: String
    internal let valueClass: RowGenerationValueClass
    internal let isNullable: Bool
    internal let hasDefault: Bool
    internal let ownership: RowGenerationServerOwnership
    internal let isUnique: Bool
    internal let reference: RowGenerationReferenceSlot?

    internal var id: String { name }

    internal init(
        name: String,
        typeName: String,
        valueClass: RowGenerationValueClass,
        isNullable: Bool = true,
        hasDefault: Bool = false,
        ownership: RowGenerationServerOwnership = .none,
        isUnique: Bool = false,
        reference: RowGenerationReferenceSlot? = nil
    ) {
        self.name = name
        self.typeName = typeName
        self.valueClass = valueClass
        self.isNullable = isNullable
        self.hasDefault = hasDefault
        self.ownership = ownership
        self.isUnique = isUnique
        self.reference = reference
    }

    internal var mayBeLeftOut: Bool {
        isNullable || hasDefault || ownership != .none
    }

    internal var maxLength: Int? {
        guard case .text(let maxLength) = valueClass else { return nil }
        return maxLength
    }

    internal var availableKinds: [RowGeneratorKind] {
        guard ownership != .computed else { return [.serverDefault] }
        var kinds: [RowGeneratorKind] = []
        if mayBeLeftOut { kinds.append(.serverDefault) }
        if reference != nil { kinds.append(.reference) }
        kinds += valueKinds
        return kinds
    }

    private var valueKinds: [RowGeneratorKind] {
        switch valueClass {
        case .integer:
            return [.sequence, .integerRange, .list]
        case .decimal, .floatingPoint:
            return [.decimalRange, .integerRange, .list]
        case .text:
            return [
                .text, .firstName, .lastName, .fullName, .email, .phone, .streetAddress, .city, .country,
                .pattern, .uuid, .sequence, .integerRange, .date, .dateTime, .list
            ]
        case .date:
            return [.date, .list]
        case .time:
            return [.time, .list]
        case .timestamp:
            return [.dateTime, .date, .list]
        case .boolean:
            return [.boolean]
        case .uuid:
            return [.uuid, .list]
        case .json:
            return [.json, .list]
        case .enumeration:
            return [.list]
        case .unsupported:
            return []
        }
    }
}

internal struct RowGenerationReferenceSource: Identifiable, Equatable, Sendable {
    internal let id: String
    internal let referencedTable: String
    internal let columns: [String]
    internal let tuples: [[PluginCellValue]]
}

internal struct RowGenerationTable: Equatable, Sendable {
    internal let columns: [RowGenerationColumn]
    // Composite unique keys and primary keys; a single-column one is the column's `isUnique`.
    internal let uniqueGroups: [[String]]
    internal let references: [RowGenerationReferenceSource]
    // The largest value an integer key column holds now, so a sequence starts past it.
    internal let keyMaximums: [String: Int64]

    internal init(
        columns: [RowGenerationColumn],
        uniqueGroups: [[String]] = [],
        references: [RowGenerationReferenceSource] = [],
        keyMaximums: [String: Int64] = [:]
    ) {
        self.columns = columns
        self.uniqueGroups = uniqueGroups
        self.references = references
        self.keyMaximums = keyMaximums
    }

    internal func column(named name: String) -> RowGenerationColumn? {
        columns.first { $0.name == name }
    }

    internal func reference(id: String) -> RowGenerationReferenceSource? {
        references.first { $0.id == id }
    }
}

internal struct RowGeneratorSettings: Codable, Equatable, Sendable {
    internal var kind: RowGeneratorKind
    internal var integerMinimum: Int64 = 1
    internal var integerMaximum: Int64 = 1_000
    internal var sequenceStep: Int64 = 1
    internal var decimalMinimum: Double = 0
    internal var decimalMaximum: Double = 1_000
    internal var decimalScale: Int = 2
    internal var minLength: Int = 5
    internal var maxLength: Int = 30
    internal var dateStart: Date
    internal var dateEnd: Date
    internal var uuidVersion: UUIDVersion = .v4
    internal var trueRatio: Double = 0.5
    internal var values: [String] = []
    internal var pattern: String = "???-####"
    internal var nullRatio: Double = 0

    internal init(kind: RowGeneratorKind, dateStart: Date, dateEnd: Date) {
        self.kind = kind
        self.dateStart = dateStart
        self.dateEnd = dateEnd
    }
}

internal struct RowGenerationSettings: Codable, Equatable, Sendable {
    internal static let maximumRowCount = 1_000_000
    internal static let defaultRowCount = 100

    internal var rowCount: Int
    internal var seed: UInt64
    internal var columns: [String: RowGeneratorSettings]

    internal init(rowCount: Int = RowGenerationSettings.defaultRowCount, seed: UInt64, columns: [String: RowGeneratorSettings]) {
        self.rowCount = rowCount
        self.seed = seed
        self.columns = columns
    }
}
