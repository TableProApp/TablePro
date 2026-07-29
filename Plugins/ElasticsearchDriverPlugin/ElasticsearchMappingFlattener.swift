//
//  ElasticsearchMappingFlattener.swift
//  ElasticsearchDriverPlugin
//
//  Flattens index mappings into columns and documents into tabular rows.
//

import Foundation
import TableProPluginKit

struct ElasticsearchColumn: Equatable {
    let name: String
    let type: String
    let hasKeywordSubfield: Bool
}

enum ElasticsearchMappingFlattener {
    private static let maxNestedJsonLength = 10_000

    static let idColumn = "_id"
    static let indexColumn = "_index"
    static let scoreColumn = "_score"
    static let metaColumns = [idColumn, indexColumn, scoreColumn]

    // MARK: - Mapping

    static func flattenMapping(properties: [String: Any]) -> [ElasticsearchColumn] {
        var columns: [ElasticsearchColumn] = []
        collect(properties: properties, prefix: "", into: &columns)
        return columns.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func collect(properties: [String: Any], prefix: String, into columns: inout [ElasticsearchColumn]) {
        for (key, raw) in properties {
            guard let field = raw as? [String: Any] else { continue }
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"

            if let nested = field["properties"] as? [String: Any] {
                collect(properties: nested, prefix: path, into: &columns)
                continue
            }

            let type = field["type"] as? String ?? "object"
            let hasKeyword = (field["fields"] as? [String: Any]).map { subfields in
                subfields.values.contains { ($0 as? [String: Any])?["type"] as? String == "keyword" }
            } ?? false
            columns.append(ElasticsearchColumn(name: path, type: type, hasKeywordSubfield: hasKeyword))
        }
    }

    static func properties(fromMappingResponse response: [String: Any], index: String) -> [String: Any] {
        let indexMapping = (response[index] as? [String: Any]) ?? response.values.first as? [String: Any]
        let mappings = indexMapping?["mappings"] as? [String: Any]
        return mappings?["properties"] as? [String: Any] ?? [:]
    }

    static func fieldInfo(from columns: [ElasticsearchColumn]) -> [String: ElasticsearchFieldInfo] {
        var result: [String: ElasticsearchFieldInfo] = [:]
        for column in columns {
            result[column.name] = ElasticsearchFieldInfo(type: column.type, hasKeywordSubfield: column.hasKeywordSubfield)
        }
        return result
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

    static func rows(forHits hits: [[String: Any]], columns: [String]) -> [[PluginCellValue]] {
        hits.map { hit in
            let source = hit["_source"] as? [String: Any] ?? [:]
            let flat = flattenSource(source)
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
                    return cell(rawValue(in: source, atPath: column))
                }
            }
        }
    }

    static func rawValue(in source: [String: Any], atPath path: String) -> Any? {
        var current: Any = source
        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(key)] else { return nil }
            current = next
        }
        return current
    }

    static func flattenSource(_ source: [String: Any]) -> [String: PluginCellValue] {
        var result: [String: PluginCellValue] = [:]
        flatten(value: source, prefix: "", into: &result)
        return result
    }

    private static func flatten(value: Any, prefix: String, into result: inout [String: PluginCellValue]) {
        if let dict = value as? [String: Any] {
            for (key, nested) in dict {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                flatten(value: nested, prefix: path, into: &result)
            }
            return
        }
        result[prefix] = cell(value)
    }

    // MARK: - Cell Conversion

    static func cell(_ value: Any?) -> PluginCellValue {
        guard let value, !(value is NSNull) else { return .null }

        switch value {
        case let string as String:
            return .text(string)
        case let number as NSNumber:
            return .text(stringFromNumber(number))
        case let array as [Any]:
            return .text(serializeJson(array))
        case let dict as [String: Any]:
            return .text(serializeJson(dict))
        default:
            return .text(String(describing: value))
        }
    }

    private static func stringFromNumber(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    }

    private static func serializeJson(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        if (json as NSString).length > maxNestedJsonLength {
            return String(json.prefix(maxNestedJsonLength)) + "..."
        }
        return json
    }
}
