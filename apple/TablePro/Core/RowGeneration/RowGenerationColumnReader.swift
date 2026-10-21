//
//  RowGenerationColumnReader.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Turns a table's catalog into what the generator needs to know about each column.
internal enum RowGenerationColumnReader {
    internal struct ReferenceRequest: Equatable, Sendable {
        internal let id: String
        internal let columns: [String]
        internal let foreignKey: ForeignKeyInfo
        internal let referencedColumns: [String]
    }

    internal struct Reading: Equatable, Sendable {
        internal let columns: [RowGenerationColumn]
        internal let uniqueGroups: [[String]]
        internal let references: [ReferenceRequest]
    }

    internal static func read(
        columns infos: [ColumnInfo],
        foreignKeys: [ForeignKeyInfo],
        indexes: [IndexInfo],
        databaseType: DatabaseType,
        hasRowID: Bool = true
    ) -> Reading {
        let family = SQLTypeFamily.of(databaseType)
        let names = Set(infos.map(\.name))
        let primaryKey = infos.filter(\.isPrimaryKey).map(\.name)
        var keys: [[String]] = primaryKey.isEmpty ? [] : [primaryKey]
        for index in indexes where index.isUnique || index.isPrimary {
            let expressions = Set(index.expressions ?? [])
            guard !index.columns.isEmpty, index.columns.allSatisfy({ names.contains($0) && !expressions.contains($0) })
            else { continue }
            keys.append(index.columns)
        }
        var seenKeys: Set<[String]> = []
        keys = keys.filter { seenKeys.insert($0.sorted()).inserted }
        let uniqueColumns = Set(keys.filter { $0.count == 1 }.map { $0[0] })

        let references = referenceRequests(foreignKeys, columns: names)
        var slots: [String: RowGenerationReferenceSlot] = [:]
        for request in references {
            for (position, column) in request.columns.enumerated() where slots[column] == nil {
                slots[column] = RowGenerationReferenceSlot(sourceId: request.id, position: position)
            }
        }

        let columns = infos.map { info in
            RowGenerationColumn(
                name: info.name,
                typeName: info.dataType,
                valueClass: valueClass(of: info, family: family),
                isNullable: info.isNullable,
                hasDefault: hasDefault(info),
                ownership: ownership(of: info, family: family, primaryKey: primaryKey, hasRowID: hasRowID),
                isUnique: uniqueColumns.contains(info.name),
                reference: slots[info.name]
            )
        }
        return Reading(columns: columns, uniqueGroups: keys.filter { $0.count > 1 }, references: references)
    }

    // A key over several columns arrives as one entry per column, sharing the constraint's name.
    private static func referenceRequests(_ foreignKeys: [ForeignKeyInfo], columns: Set<String>) -> [ReferenceRequest] {
        var order: [String] = []
        var grouped: [String: [ForeignKeyInfo]] = [:]
        for foreignKey in foreignKeys where columns.contains(foreignKey.column) {
            let id = foreignKey.name.isEmpty
                ? "\(foreignKey.column)\u{1F}\(foreignKey.referencedTable)"
                : "\(foreignKey.name)\u{1F}\(foreignKey.referencedTable)"
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(foreignKey)
        }
        return order.compactMap { id in
            guard let members = grouped[id], let first = members.first else { return nil }
            return ReferenceRequest(
                id: id,
                columns: members.map(\.column),
                foreignKey: first,
                referencedColumns: members.map(\.referencedColumn)
            )
        }
    }

    // The table options follow the column list's closing parenthesis, as `STRICT` or `WITHOUT ROWID` in either order.
    internal static func declaresWithoutRowID(_ definition: String?) -> Bool {
        guard let definition else { return false }
        let pattern = #"\)\s*(STRICT\s*,\s*)?WITHOUT\s+ROWID\b"#
        return definition.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasDefault(_ info: ColumnInfo) -> Bool {
        guard let value = info.defaultValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return false }
        return !ColumnDefaultLiteral.isNull(value)
    }

    private static func ownership(
        of info: ColumnInfo,
        family: SQLTypeFamily,
        primaryKey: [String],
        hasRowID: Bool
    ) -> RowGenerationServerOwnership {
        if info.isGenerated || info.identityKind == .always { return .computed }
        if info.identityKind != nil { return .assigned }
        if let value = info.defaultValue,
           CrossEngineDefaultValue.strippingCast(value).uppercased().hasPrefix("NEXTVAL(") {
            return .assigned
        }
        // SQLite's INTEGER PRIMARY KEY is the rowid: left out, it takes the next one. A WITHOUT ROWID table has none.
        if family == .sqlite, hasRowID, primaryKey == [info.name],
           info.dataType.trimmingCharacters(in: .whitespaces).uppercased() == "INTEGER" {
            return .assigned
        }
        return .none
    }

    internal static func valueClass(of info: ColumnInfo, family: SQLTypeFamily) -> RowGenerationValueClass {
        if let labels = info.allowedValues, !labels.isEmpty { return .enumeration(labels) }
        if let labels = EnumValueParser.parseMySQLEnumOrSet(from: info.typeNameForClassification), !labels.isEmpty {
            return .enumeration(labels)
        }
        if family == .mysql, info.typeNameForClassification.uppercased().hasPrefix("YEAR") {
            return .integer(minimum: 1_901, maximum: 2_155)
        }
        let parsed = SQLTypeParser.parse(info.typeNameForClassification, catalogSpelling: info.ddlSpelling, family: family)
        switch parsed.kind {
        case .boolean: return .boolean
        case .integer(let bytes): return integerClass(bytes: bytes, isUnsigned: parsed.isUnsigned)
        case .decimal(let precision, let scale): return .decimal(precision: precision, scale: scale)
        case .money: return .decimal(precision: nil, scale: 2)
        case .floatingPoint: return .floatingPoint
        case .text(let length, _): return .text(maxLength: length)
        case .date: return .date
        case .time: return .time
        case .timestamp: return .timestamp
        case .uuid: return .uuid
        case .json: return .json
        case .enumeration(let values): return values.isEmpty ? .unsupported : .enumeration(values)
        case .binary, .interval, .xml, .bitString, .spatial, .array:
            return .unsupported
        case .unsupported:
            return fallbackClass(of: info, family: family)
        }
    }

    // A type no family names, such as a domain or `citext` read without its catalog spelling, takes the class the
    // grid shows it as.
    private static func fallbackClass(of info: ColumnInfo, family: SQLTypeFamily) -> RowGenerationValueClass {
        switch ColumnTypeClassifier(family: family).classify(rawTypeName: info.typeNameForClassification) {
        case .text: return .text(maxLength: nil)
        case .integer: return integerClass(bytes: 8, isUnsigned: false)
        case .decimal: return .decimal(precision: nil, scale: nil)
        case .date: return .date
        case .timestamp, .datetime: return .timestamp
        case .boolean: return .boolean
        case .json: return .json
        case .enumType(_, let values), .set(_, let values):
            guard let values, !values.isEmpty else { return .unsupported }
            return .enumeration(values)
        case .blob, .spatial, .vector, .array:
            return .unsupported
        }
    }

    private static func integerClass(bytes: Int, isUnsigned: Bool) -> RowGenerationValueClass {
        let bits = min(64, max(8, bytes * 8))
        if isUnsigned {
            let maximum: Int64 = bits >= 64 ? .max : (Int64(1) << bits) - 1
            return .integer(minimum: 0, maximum: maximum)
        }
        let maximum: Int64 = bits >= 64 ? .max : (Int64(1) << (bits - 1)) - 1
        return .integer(minimum: bits >= 64 ? .min : -maximum - 1, maximum: maximum)
    }
}
