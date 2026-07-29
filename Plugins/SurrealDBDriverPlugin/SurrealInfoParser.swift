//
//  SurrealInfoParser.swift
//  SurrealDBDriverPlugin
//

import Foundation
import TableProPluginKit

public struct SurrealTableDescriptor: Equatable, Sendable {
    public let name: String
    public let isSchemafull: Bool
    public let isRelation: Bool

    public init(name: String, isSchemafull: Bool, isRelation: Bool) {
        self.name = name
        self.isSchemafull = isSchemafull
        self.isRelation = isRelation
    }
}

public enum SurrealInfoParser {
    public static let recordIdColumn = "id"
    public static let edgeInColumn = "in"
    public static let edgeOutColumn = "out"

    public static func names(from value: SurrealValue, key: String) -> [String] {
        guard let entries = value[key]?.objectPairs else { return [] }
        return entries.map(\.key).sorted()
    }

    public static func tables(from value: SurrealValue) -> [SurrealTableDescriptor] {
        if let structured = value["tables"]?.arrayValues {
            return structured.compactMap(structuredTable).sorted { $0.name < $1.name }
        }
        guard let entries = value["tables"]?.objectPairs else { return [] }
        return entries
            .map { entry in
                let definition = entry.value.stringValue ?? ""
                return SurrealTableDescriptor(
                    name: entry.key,
                    isSchemafull: definition.uppercased().contains("SCHEMAFULL"),
                    isRelation: definition.uppercased().contains("TYPE RELATION")
                )
            }
            .sorted { $0.name < $1.name }
    }

    public static func columns(from value: SurrealValue, isRelation: Bool) -> [PluginColumnInfo] {
        let fields = fieldEntries(from: value)
        var columns: [PluginColumnInfo] = [
            PluginColumnInfo(
                name: recordIdColumn,
                dataType: "record",
                isNullable: false,
                isPrimaryKey: true
            )
        ]
        if isRelation {
            columns.append(edgeColumn(edgeInColumn))
            columns.append(edgeColumn(edgeOutColumn))
        }

        for field in fields where !isReservedColumn(field.name) {
            let kind = SurrealFieldKind.parse(field.kind)
            columns.append(
                PluginColumnInfo(
                    name: field.name,
                    dataType: field.kind.isEmpty ? "any" : field.kind,
                    isNullable: kind.isOptional,
                    isPrimaryKey: false
                )
            )
        }
        return columns
    }

    public static func indexes(from value: SurrealValue) -> [PluginIndexInfo] {
        guard let entries = value["indexes"] else { return [] }

        if let structured = entries.arrayValues {
            return structured.compactMap { entry in
                guard let name = entry["name"]?.stringValue else { return nil }
                let definition = (entry["index"]?.stringValue ?? "").uppercased()
                return PluginIndexInfo(
                    name: name,
                    columns: indexColumns(entry["cols"]),
                    isUnique: definition.contains("UNIQUE"),
                    isPrimary: false,
                    type: definition.isEmpty ? "INDEX" : definition
                )
            }
        }

        guard let pairs = entries.objectPairs else { return [] }
        return pairs.map { pair in
            let definition = (pair.value.stringValue ?? "").uppercased()
            return PluginIndexInfo(
                name: pair.key,
                columns: [],
                isUnique: definition.contains("UNIQUE"),
                isPrimary: false,
                type: "INDEX"
            )
        }
    }

    public static func definitions(from value: SurrealValue) -> [String] {
        var lines: [String] = []
        for section in ["fields", "indexes", "events", "tables", "lives"] {
            guard let pairs = value[section]?.objectPairs else { continue }
            for pair in pairs {
                guard let text = pair.value.stringValue, !text.isEmpty else { continue }
                lines.append(text.hasSuffix(";") ? text : text + ";")
            }
        }
        return lines
    }

    public static func isReservedColumn(_ name: String) -> Bool {
        name == recordIdColumn || name == edgeInColumn || name == edgeOutColumn
    }

    public static func isNestedFieldName(_ name: String) -> Bool {
        name.contains(".") || name.contains("[")
    }

    // MARK: - Helpers

    private static func edgeColumn(_ name: String) -> PluginColumnInfo {
        PluginColumnInfo(name: name, dataType: "record", isNullable: false, isPrimaryKey: false)
    }

    private static func structuredTable(_ entry: SurrealValue) -> SurrealTableDescriptor? {
        guard let name = entry["name"]?.stringValue else { return nil }
        let schemafull = entry["schemafull"]?.boolValue ?? entry["full"]?.boolValue ?? false
        let kind = entry["kind"]?["kind"]?.stringValue?.uppercased()
        return SurrealTableDescriptor(
            name: name,
            isSchemafull: schemafull,
            isRelation: kind == "RELATION"
        )
    }

    private static func fieldEntries(from value: SurrealValue) -> [(name: String, kind: String)] {
        guard let fields = value["fields"] else { return [] }

        if let structured = fields.arrayValues {
            return structured.compactMap { field in
                guard let name = field["name"]?.stringValue, !isNestedFieldName(name) else { return nil }
                return (name: name, kind: field["kind"]?.stringValue ?? "")
            }
        }

        guard let pairs = fields.objectPairs else { return [] }
        return pairs.compactMap { pair in
            guard !isNestedFieldName(pair.key) else { return nil }
            return (name: pair.key, kind: kindFromDefinition(pair.value.stringValue ?? ""))
        }
    }

    private static func kindFromDefinition(_ definition: String) -> String {
        guard let range = definition.range(of: " TYPE ") else { return "" }
        let tail = definition[range.upperBound...]
        let terminators = [" PERMISSIONS", " DEFAULT", " VALUE", " ASSERT", " READONLY", " COMMENT"]
        var end = tail.endIndex
        for terminator in terminators {
            if let found = tail.range(of: terminator), found.lowerBound < end {
                end = found.lowerBound
            }
        }
        return String(tail[tail.startIndex..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func indexColumns(_ value: SurrealValue?) -> [String] {
        guard let value else { return [] }
        if let items = value.arrayValues {
            return items.compactMap { $0.stringValue }
        }
        guard let single = value.stringValue else { return [] }
        return single
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
