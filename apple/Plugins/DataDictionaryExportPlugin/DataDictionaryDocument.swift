//
//  DataDictionaryDocument.swift
//  DataDictionaryExportPlugin
//

import Foundation
import TableProPluginKit

struct DataDictionaryObject: Sendable {
    let name: String
    let container: String?
    let kind: PluginExportObjectKind
    var comment: String?
    var columns: [PluginColumnInfo] = []
    var indexes: [PluginIndexInfo] = []
    var foreignKeys: [PluginForeignKeyInfo] = []
    var columnsError: String?

    var kindLabel: String {
        switch kind {
        case .view: "View"
        case .materializedView: "Materialized view"
        case .foreignTable: "Foreign table"
        default: "Table"
        }
    }
}

struct DataDictionaryColumnRow: Equatable {
    let name: String
    let type: String
    let isNullable: Bool
    let defaultText: String?
    let isPrimaryKey: Bool
    let references: [DataDictionaryReference]
    let comment: String?
}

struct DataDictionaryReference: Equatable {
    let table: String
    let column: String?
    let anchor: String?

    var text: String {
        guard let column else { return table }
        return "\(table).\(column)"
    }
}

struct DataDictionaryIndexRow: Equatable {
    let name: String
    let columns: String
    let kind: String
    let method: String
}

struct DataDictionaryForeignKeyRow: Equatable {
    let name: String
    let columns: [String]
    let target: DataDictionaryReference
    let referencedColumns: [String]
    let onDelete: String
    let onUpdate: String
}

// Everything both renderers need, decided once so the Markdown and HTML files never disagree.
struct DataDictionaryDocument {
    let title: String
    let databaseTypeId: String
    let generatedAt: Date
    let objects: [DataDictionaryObject]
    let anchors: [String]
    private let anchorByTable: [String: String]
    let qualifiesNames: Bool
    let showsDefault: Bool
    let showsKey: Bool
    let showsReferences: Bool
    let showsColumnComment: Bool

    init(title: String, databaseTypeId: String, generatedAt: Date, objects: [DataDictionaryObject]) {
        self.title = title
        self.databaseTypeId = databaseTypeId
        self.generatedAt = generatedAt
        self.objects = objects
        let qualifies = Set(objects.map { $0.container ?? "" }).count > 1
        self.qualifiesNames = qualifies
        let anchors = DataDictionaryAnchors.make(for: objects.map { Self.displayName(of: $0, qualified: qualifies) })
        self.anchors = anchors
        var anchorByTable: [String: String] = [:]
        for (object, anchor) in zip(objects, anchors) {
            let key = Self.tableKey(container: object.container, name: object.name)
            if anchorByTable[key] == nil { anchorByTable[key] = anchor }
        }
        self.anchorByTable = anchorByTable
        self.showsDefault = objects.contains { object in object.columns.contains { Self.defaultText(of: $0) != nil } }
        self.showsKey = objects.contains { object in object.columns.contains(where: \.isPrimaryKey) }
        self.showsReferences = objects.contains { !$0.foreignKeys.isEmpty }
        self.showsColumnComment = objects.contains { object in object.columns.contains { Self.hasText($0.comment) } }
    }

    func displayName(at index: Int) -> String {
        Self.displayName(of: objects[index], qualified: qualifiesNames)
    }

    func summary() -> String {
        let counts = Dictionary(grouping: objects, by: \.kindLabel).mapValues(\.count)
        let parts = ["Table", "View", "Materialized view", "Foreign table"].compactMap { label -> String? in
            guard let count = counts[label] else { return nil }
            let noun = label.lowercased()
            return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm xxx"
        let when = formatter.string(from: generatedAt)
        let source = databaseTypeId.isEmpty ? "" : " from \(databaseTypeId)"
        let contents = parts.isEmpty ? "" : ": \(parts.joined(separator: ", "))"
        return "Data dictionary generated \(when)\(source)\(contents)."
    }

    func columnRows(at index: Int) -> [DataDictionaryColumnRow] {
        let object = objects[index]
        return object.columns.map { column in
            let references = object.foreignKeys
                .filter { $0.column == column.name }
                .map { reference(to: $0, from: object) }
            return DataDictionaryColumnRow(
                name: column.name,
                type: column.dataType,
                isNullable: column.isNullable,
                defaultText: Self.defaultText(of: column),
                isPrimaryKey: column.isPrimaryKey,
                references: references,
                comment: Self.hasText(column.comment) ? column.comment : nil
            )
        }
    }

    func indexRows(at index: Int) -> [DataDictionaryIndexRow] {
        objects[index].indexes.map { info in
            var keys = info.columns.joined(separator: ", ")
            if let included = info.includedColumns, !included.isEmpty {
                keys += " INCLUDE (\(included.joined(separator: ", ")))"
            }
            if let condition = info.whereClause, Self.hasText(condition) {
                keys += " WHERE \(condition)"
            }
            let kind = info.isPrimary ? "Primary key" : (info.isUnique ? "Unique" : "Index")
            return DataDictionaryIndexRow(name: info.name, columns: keys, kind: kind, method: info.type)
        }
    }

    // A composite key arrives as one entry per column under one name.
    func foreignKeyRows(at index: Int) -> [DataDictionaryForeignKeyRow] {
        let object = objects[index]
        var order: [String] = []
        var groups: [String: [PluginForeignKeyInfo]] = [:]
        for key in object.foreignKeys {
            if groups[key.name] == nil { order.append(key.name) }
            groups[key.name, default: []].append(key)
        }
        return order.compactMap { name in
            guard let group = groups[name], let first = group.first else { return nil }
            return DataDictionaryForeignKeyRow(
                name: name,
                columns: group.map(\.column),
                target: reference(to: first, from: object, includesColumn: false),
                referencedColumns: group.map(\.referencedColumn),
                onDelete: first.onDelete,
                onUpdate: first.onUpdate
            )
        }
    }

    private func reference(
        to key: PluginForeignKeyInfo,
        from object: DataDictionaryObject,
        includesColumn: Bool = true
    ) -> DataDictionaryReference {
        let schema = Self.hasText(key.referencedSchema) ? key.referencedSchema : nil
        let database = Self.hasText(key.referencedDatabase) ? key.referencedDatabase : nil
        let targetContainer = schema ?? object.container
        var parts: [String] = []
        if let database { parts.append(database) }
        if let schema, database != nil || schema != object.container { parts.append(schema) }
        parts.append(key.referencedTable)
        let anchor = database == nil
            ? anchorByTable[Self.tableKey(container: targetContainer, name: key.referencedTable)]
            : nil
        return DataDictionaryReference(
            table: parts.joined(separator: "."),
            column: includesColumn ? key.referencedColumn : nil,
            anchor: anchor
        )
    }

    private static func tableKey(container: String?, name: String) -> String {
        "\(container ?? "")\u{1F}\(name)"
    }

    static func displayName(of object: DataDictionaryObject, qualified: Bool) -> String {
        guard qualified, let container = object.container, !container.isEmpty else { return object.name }
        return "\(container).\(object.name)"
    }

    static func defaultText(of column: PluginColumnInfo) -> String? {
        if let value = column.defaultValue, hasText(value) { return value }
        if let expression = column.generationExpression, hasText(expression) {
            let storage = column.generationKind.map { " \($0.rawValue)" } ?? ""
            return "GENERATED ALWAYS AS (\(expression))\(storage)"
        }
        if let identity = column.identityKind { return "GENERATED \(identity.rawValue) AS IDENTITY" }
        if column.extra?.lowercased().contains("auto_increment") == true { return "AUTO_INCREMENT" }
        return nil
    }

    static func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum DataDictionaryAnchors {
    static let contents = "contents"

    // Explicit ids, because every Markdown renderer derives heading slugs its own way.
    static func make(for names: [String]) -> [String] {
        var used: Set<String> = [contents]
        return names.map { name in
            let base = slug(name)
            var candidate = base
            var suffix = 2
            while used.contains(candidate) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            used.insert(candidate)
            return candidate
        }
    }

    static func slug(_ name: String) -> String {
        var result = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber || character == "_" {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "object" : result
    }
}
