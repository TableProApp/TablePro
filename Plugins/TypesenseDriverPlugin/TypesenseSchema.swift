//
//  TypesenseSchema.swift
//  TypesenseDriverPlugin
//
//  Collection schemas, column flattening and document to cell conversion.
//

import Foundation
import TableProNumberFormatting
import TableProPluginKit

struct TypesenseField: Equatable {
    let name: String
    let type: String
    let isSortable: Bool
    let isOptional: Bool
    let isFacet: Bool

    var isNumeric: Bool { TypesenseSchema.numericTypes.contains(type) }
    var isBoolean: Bool { TypesenseSchema.booleanTypes.contains(type) }
    var isString: Bool { TypesenseSchema.stringTypes.contains(type) }
    var isObject: Bool { TypesenseSchema.objectTypes.contains(type) }
}

struct TypesenseCollection: Equatable {
    let name: String
    let numDocuments: Int
    let defaultSortingField: String?
    let fields: [TypesenseField]

    var presentedFields: [TypesenseField] {
        TypesenseSchema.presentedFields(fields)
    }

    var columns: [String] {
        [TypesenseSchema.idColumn] + presentedFields.map(\.name)
    }

    /// `id` never appears in a collection's `fields`, but it filters like a string field, so the
    /// lookup a filter reads has to carry it or every `id` predicate loses its quoting.
    var fieldsByName: [String: TypesenseField] {
        let pairs = ([TypesenseSchema.idField] + presentedFields).map { ($0.name, $0) }
        return Dictionary(pairs, uniquingKeysWith: { _, last in last })
    }
}

/// Percent-encoding for one path segment of a Typesense REST URL.
///
/// A collection name and a document id are both free text: measured on 29.0, Typesense accepts a
/// collection called `a/b` and a document whose id is `..`. `.urlPathAllowed` passes both `/` and
/// `.` through, so `a/b` addressed `/collections/a/b` and answered 404 while the collection sat
/// there in the sidebar. Encoding both makes the segment opaque, and Typesense decodes `%2F` and
/// `%2E` back to the name it stored.
enum TypesensePathEncoding {
    private static let segmentAllowed: CharacterSet =
        .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/."))

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? value
    }

    /// Resolves a request path against the connection's own base URL, and refuses anything that
    /// lands somewhere else.
    ///
    /// A path beginning with `//` is a network-path reference, so `URL(string:relativeTo:)` reads
    /// what follows as a host: `//attacker.example/x` resolves to `http://attacker.example/x`. The
    /// API key header rides on every request the driver sends, so a console request typed with
    /// that shape would hand the key to whatever host it named.
    static func resolve(_ path: String, against baseURL: URL) -> URL? {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme,
              url.host == baseURL.host,
              url.port == baseURL.port
        else { return nil }
        return url
    }
}

enum TypesenseSchema {
    private static let maxNestedJsonLength = 10_000

    static let idColumn = "id"

    /// Typesense will not sort on `id`: "Could not find a field named `id` in the schema for sorting."
    static let idField = TypesenseField(
        name: idColumn, type: "string", isSortable: false, isOptional: false, isFacet: false
    )

    /// An auto-schema collection declares `{"name": ".*", "type": "auto"}` and Typesense keeps
    /// that entry alongside the fields it learns from documents. It is not a column.
    static let wildcardField = ".*"

    static let numericTypes: Set<String> = [
        "int32", "int64", "float", "int32[]", "int64[]", "float[]",
    ]
    static let booleanTypes: Set<String> = ["bool", "bool[]"]
    static let stringTypes: Set<String> = ["string", "string[]", "string*", "auto"]
    static let objectTypes: Set<String> = ["object", "object[]"]

    // MARK: - Decoding

    static func collections(from json: Any?) -> [TypesenseCollection] {
        guard let array = json as? [[String: Any]] else { return [] }
        return array.compactMap { collection(from: $0) }
    }

    static func collection(from json: [String: Any]) -> TypesenseCollection? {
        guard let name = json["name"] as? String else { return nil }
        let rawFields = json["fields"] as? [[String: Any]] ?? []
        let defaultSort = json["default_sorting_field"] as? String
        return TypesenseCollection(
            name: name,
            numDocuments: (json["num_documents"] as? Int) ?? 0,
            defaultSortingField: (defaultSort?.isEmpty ?? true) ? nil : defaultSort,
            fields: rawFields.compactMap { field(from: $0) }
        )
    }

    static func field(from json: [String: Any]) -> TypesenseField? {
        guard let name = json["name"] as? String, let type = json["type"] as? String else { return nil }
        return TypesenseField(
            name: name,
            type: type,
            isSortable: (json["sort"] as? Bool) ?? false,
            isOptional: (json["optional"] as? Bool) ?? false,
            isFacet: (json["facet"] as? Bool) ?? false
        )
    }

    // MARK: - Columns

    /// A nested object is reported twice: the `object` parent and every dotted leaf under it.
    /// Only the leaves become columns, and the parent survives only while it has no leaves yet.
    static func presentedFields(_ fields: [TypesenseField]) -> [TypesenseField] {
        let names = Set(fields.map(\.name))
        return fields
            .filter { $0.name != wildcardField && $0.name != idColumn }
            .filter { field in
                guard field.isObject else { return true }
                return !names.contains { $0.hasPrefix("\(field.name).") }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func unionColumns(fromDocuments documents: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for document in documents {
            for key in flatten(document).keys where !seen.contains(key) {
                seen.insert(key)
                ordered.append(key)
            }
        }
        let rest = ordered.filter { $0 != idColumn }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return ordered.contains(idColumn) ? [idColumn] + rest : rest
    }

    static func typeNames(for columns: [String], fields: [String: TypesenseField]) -> [String] {
        columns.map { column in
            column == idColumn ? "string" : (fields[column]?.type ?? "")
        }
    }

    // MARK: - Rows

    static func rows(for documents: [[String: Any]], columns: [String]) -> [[PluginCellValue]] {
        documents.map { document in
            let flat = flatten(document)
            return columns.map { column in
                if let value = flat[column] { return value }
                return cell(rawValue(in: document, atPath: column))
            }
        }
    }

    /// An `object[]` field is reported by the schema as its dotted leaves (`variants.sku`) while
    /// the document keeps the original array of objects, so walking dictionaries alone reaches
    /// nothing and every value of such a column renders blank. An array is a container rather than
    /// a level of the path: the remaining keys are read from each of its elements, which is the
    /// same shape Typesense gives the leaf, a `string[]` of one value per element.
    static func rawValue(in document: [String: Any], atPath path: String) -> Any? {
        value(in: document, keys: path.split(separator: ".").map(String.init)[...])
    }

    private static func value(in current: Any, keys: ArraySlice<String>) -> Any? {
        guard let key = keys.first else { return current }
        if let dictionary = current as? [String: Any] {
            guard let next = dictionary[key] else { return nil }
            return value(in: next, keys: keys.dropFirst())
        }
        if let array = current as? [Any] {
            let collected = array.compactMap { value(in: $0, keys: keys) }
            return collected.isEmpty ? nil : collected
        }
        return nil
    }

    static func flatten(_ document: [String: Any]) -> [String: PluginCellValue] {
        var result: [String: PluginCellValue] = [:]
        flatten(value: document, prefix: "", into: &result)
        return result
    }

    private static func flatten(value: Any, prefix: String, into result: inout [String: PluginCellValue]) {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
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
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .text(number.boolValue ? "true" : "false")
            }
            return .text(NumberText.text(for: number))
        case let array as [Any]:
            return .text(serializeJson(array))
        case let dictionary as [String: Any]:
            return .text(serializeJson(dictionary))
        default:
            return .text(String(describing: value))
        }
    }

    private static func serializeJson(_ value: Any) -> String {
        guard let json = NumberText.json(from: value) else { return String(describing: value) }
        return JSONTruncation.truncate(json, maxLength: maxNestedJsonLength)
    }
}
