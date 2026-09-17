//
//  ElasticsearchMappingFlattener.swift
//  ElasticsearchDriverPlugin
//
//  Flattens index mappings into columns and documents into tabular rows.
//

import Foundation
import TableProDocumentPath
import TableProNumberFormatting
import TableProPluginKit

struct ElasticsearchColumn: Equatable {
    let name: String
    let type: String
    let hasKeywordSubfield: Bool

    /// Ancestor paths declared `nested`, outermost first. A leaf of a mapping that nests twice
    /// reports both, and a query has to enter each scope in that order to stay bound to one
    /// element at every level.
    let nestedPaths: [String]

    var nestedPath: String? { nestedPaths.last }

    init(name: String, type: String, hasKeywordSubfield: Bool, nestedPaths: [String] = []) {
        self.name = name
        self.type = type
        self.hasKeywordSubfield = hasKeywordSubfield
        self.nestedPaths = nestedPaths
    }
}

enum ElasticsearchMappingFlattener {
    private static let maxNestedJsonLength = 10_000
    /// A `geo_shape` polygon passes 10,000 characters without being unusual, and half a geometry is
    /// not a geometry: the truncated text parses as nothing, so the map drew nothing for a shape the
    /// grid was showing. A geometry is kept whole up to a ceiling that still protects the grid from
    /// a value no reader would finish.
    private static let maxGeometryJsonLength = 1_000_000

    /// Elasticsearch accepts a `geo_shape` type name in any case, so the comparison is lowercased.
    private static let geometryTypeNames: Set<String> = [
        "point", "multipoint", "linestring", "multilinestring",
        "polygon", "multipolygon", "geometrycollection", "envelope", "circle"
    ]

    static let nestedTypeName = "nested"

    static let idColumn = "_id"
    static let indexColumn = "_index"
    static let scoreColumn = "_score"
    static let metaColumns = [idColumn, indexColumn, scoreColumn]

    // MARK: - Mapping

    static func flattenMapping(properties: [String: Any]) -> [ElasticsearchColumn] {
        var columns: [ElasticsearchColumn] = []
        collect(properties: properties, prefix: "", nestedPaths: [], into: &columns)
        return columns.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func collect(
        properties: [String: Any],
        prefix: String,
        nestedPaths: [String],
        into columns: inout [ElasticsearchColumn]
    ) {
        for (key, raw) in properties {
            guard let field = raw as? [String: Any] else { continue }
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            let type = field["type"] as? String
            let isNested = type == nestedTypeName

            guard let children = field["properties"] as? [String: Any] else {
                let hasKeyword = (field["fields"] as? [String: Any]).map { subfields in
                    subfields.values.contains { ($0 as? [String: Any])?["type"] as? String == "keyword" }
                } ?? false
                columns.append(ElasticsearchColumn(
                    name: path,
                    type: type ?? "object",
                    hasKeywordSubfield: hasKeyword,
                    nestedPaths: nestedPaths
                ))
                continue
            }

            if isNested {
                columns.append(ElasticsearchColumn(
                    name: path,
                    type: nestedTypeName,
                    hasKeywordSubfield: false,
                    nestedPaths: nestedPaths
                ))
            }
            collect(
                properties: children,
                prefix: path,
                nestedPaths: isNested ? nestedPaths + [path] : nestedPaths,
                into: &columns
            )
        }
    }

    /// An alias or a wildcard resolves to several indices and the response is keyed by each real
    /// index name, so the name asked for is often absent. Taking any one of them gives that index's
    /// columns for every index behind the alias; the union gives the columns the alias can actually
    /// return, and the first index to declare a field wins so the result does not depend on
    /// dictionary order.
    static func properties(fromMappingResponse response: [String: Any], index: String) -> [String: Any] {
        if let exact = properties(ofIndexMapping: response[index]) { return exact }
        var merged: [String: Any] = [:]
        for key in response.keys.sorted() {
            guard let properties = properties(ofIndexMapping: response[key]) else { continue }
            for (name, field) in properties where merged[name] == nil {
                merged[name] = field
            }
        }
        return merged
    }

    private static func properties(ofIndexMapping mapping: Any?) -> [String: Any]? {
        guard let indexMapping = mapping as? [String: Any],
              let mappings = indexMapping["mappings"] as? [String: Any]
        else { return nil }
        return mappings["properties"] as? [String: Any]
    }

    static func fieldInfo(from columns: [ElasticsearchColumn]) -> [String: ElasticsearchFieldInfo] {
        var result: [String: ElasticsearchFieldInfo] = [:]
        for column in columns {
            result[column.name] = ElasticsearchFieldInfo(
                type: column.type,
                hasKeywordSubfield: column.hasKeywordSubfield,
                nestedPaths: column.nestedPaths
            )
        }
        return result
    }

    static func nestedParents(from columns: [ElasticsearchColumn]) -> Set<String> {
        Set(columns.filter { $0.type == nestedTypeName }.map(\.name))
    }

    // MARK: - Columns From Hits

    static func unionColumns(fromSources sources: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for source in sources {
            for key in flattenSource(source).keys where !seen.contains(key) {
                seen.insert(key)
                ordered.append(key)
            }
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func columns(forHits hits: [[String: Any]], mappingColumns: [ElasticsearchColumn]) -> [String] {
        let dataColumns = mappingColumns.isEmpty
            ? unionColumns(fromSources: hits.compactMap { $0["_source"] as? [String: Any] })
            : mappingColumns.map(\.name)
        return metaColumns + dataColumns
    }

    // MARK: - Rows

    static func rows(
        forHits hits: [[String: Any]],
        columns: [String],
        nestedParents: Set<String> = []
    ) -> [[PluginCellValue]] {
        hits.map { hit in
            let source = hit["_source"] as? [String: Any] ?? [:]
            let flat = flattenSource(source, nestedParents: nestedParents)
            return columns.map { column in
                switch column {
                case idColumn:
                    return cell(hit["_id"])
                case indexColumn:
                    return cell(hit["_index"])
                case scoreColumn:
                    return cell(hit["_score"])
                default:
                    if let value = flat[column] { return value }
                    return cell(DocumentPath.value(in: source, atPath: column))
                }
            }
        }
    }

    static func flattenSource(
        _ source: [String: Any],
        nestedParents: Set<String> = []
    ) -> [String: PluginCellValue] {
        var result: [String: PluginCellValue] = [:]
        flatten(value: source, prefix: "", nestedParents: nestedParents, into: &result)
        return result
    }

    private static func flatten(
        value: Any,
        prefix: String,
        nestedParents: Set<String>,
        into result: inout [String: PluginCellValue]
    ) {
        if let elements = elementObjects(value, at: prefix, nestedParents: nestedParents) {
            result[prefix] = cell(elements)
            flattenElements(elements, prefix: prefix, into: &result)
            return
        }
        guard let dictionary = value as? [String: Any] else {
            result[prefix] = cell(value)
            return
        }
        for (key, nested) in dictionary {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            flatten(value: nested, prefix: path, nestedParents: nestedParents, into: &result)
        }
    }

    /// Elasticsearch accepts one bare object wherever a `nested` field takes an array of them, and
    /// both have to reach the grid as the same shape or one column holds a scalar on one row and a
    /// JSON array on the next.
    private static func elementObjects(_ value: Any, at prefix: String, nestedParents: Set<String>) -> [Any]? {
        if let array = value as? [Any], array.contains(where: { $0 is [String: Any] }) { return array }
        guard nestedParents.contains(prefix), value is [String: Any] else { return nil }
        return [value]
    }

    private static func flattenElements(
        _ elements: [Any],
        prefix: String,
        into result: inout [String: PluginCellValue]
    ) {
        let maps = elements.map { element -> [String: Any] in
            var raw: [String: Any] = [:]
            flattenRaw(value: element, prefix: prefix, into: &raw)
            return raw
        }

        var seen = Set<String>()
        var order: [String] = []
        for map in maps {
            for key in map.keys.sorted() {
                guard key != prefix, !seen.contains(key) else { continue }
                seen.insert(key)
                order.append(key)
            }
        }

        for key in order {
            result[key] = cell(maps.map { $0[key] ?? NSNull() })
        }
    }

    private static func flattenRaw(value: Any, prefix: String, into result: inout [String: Any]) {
        guard let dictionary = value as? [String: Any] else {
            result[prefix] = value
            return
        }
        for (key, nested) in dictionary {
            flattenRaw(value: nested, prefix: prefix.isEmpty ? key : "\(prefix).\(key)", into: &result)
        }
    }

    // MARK: - Cell Conversion

    static func cell(_ value: Any?) -> PluginCellValue {
        guard let value, !(value is NSNull) else { return .null }

        switch value {
        case let string as String:
            return .text(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .text(number.boolValue ? "true" : "false")
            }
            return .text(NumberText.text(for: number))
        case let array as [Any]:
            return .text(serializeJson(array))
        case let dict as [String: Any]:
            return .text(serializeJson(dict))
        default:
            return .text(String(describing: value))
        }
    }

    private static func serializeJson(_ value: Any) -> String {
        guard let json = NumberText.json(from: value) else {
            return String(describing: value)
        }
        let limit = isGeometry(value) ? maxGeometryJsonLength : maxNestedJsonLength
        return JSONTruncation.truncate(json, maxLength: limit)
    }

    private static func isGeometry(_ value: Any) -> Bool {
        guard let dict = value as? [String: Any], let type = dict["type"] as? String else { return false }
        guard geometryTypeNames.contains(type.lowercased()) else { return false }
        return dict["coordinates"] != nil || dict["geometries"] != nil
    }
}
