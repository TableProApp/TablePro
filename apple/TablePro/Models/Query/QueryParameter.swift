//
//  QueryParameter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum QueryParameterType: String, Codable, CaseIterable, Sendable {
    case string
    case integer
    case decimal
    case date
    case boolean
}

struct QueryParameter: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    var value: String
    var type: QueryParameterType
    var isNull: Bool

    init(name: String, value: String = "", type: QueryParameterType = .string, isNull: Bool = false) {
        self.id = UUID()
        self.name = name
        self.value = value
        self.type = type
        self.isNull = isNull
    }
}

extension QueryParameterType {
    // String is the panel's default, so a plain number in it still goes as a number (`LIMIT :n`, `id = :id`). Anything
    // else is text, a code like `1E5` included; Decimal sends that as a number.
    func pluginKind(for value: String) -> PluginColumnKind? {
        switch self {
        case .string: return Self.isPlainNumber(value) ? nil : .text
        case .integer: return .integer
        case .decimal: return .decimal
        case .boolean: return .boolean
        case .date: return .other
        }
    }

    // Digits with an optional sign and an optional fraction: `42`, `-3.5`, `.5`.
    private static func isPlainNumber(_ value: String) -> Bool {
        var scalars = value.unicodeScalars[...]
        if scalars.first == "-" || scalars.first == "+" { scalars = scalars.dropFirst() }
        var sawDot = false
        var digitsAfterDot = 0
        var digits = 0
        for scalar in scalars {
            if ("0"..."9").contains(scalar) {
                digits += 1
                if sawDot { digitsAfterDot += 1 }
            } else if scalar == ".", !sawDot {
                sawDot = true
            } else {
                return false
            }
        }
        return digits > 0 && (!sawDot || digitsAfterDot > 0)
    }
}

// A panel value with the type the user gave it, so a driver that writes values into the statement writes it as that.
struct TypedParameterValue: Equatable, Sendable {
    let text: String
    let kind: PluginColumnKind?

    // A run's value as the rerun state keeps it; plain text from a caller that gave no type stays text with no kind.
    static func kept(_ value: Any?) -> TypedParameterValue? {
        if let typed = value as? TypedParameterValue { return typed }
        return (value as? String).map { TypedParameterValue(text: $0, kind: nil) }
    }

    // Nil when no value carries a type, so a driver reads the values as it did before types were passed.
    static func kinds(of parameters: [Any?]?) -> [PluginColumnKind?]? {
        guard let parameters else { return nil }
        let kinds = parameters.map { ($0 as? TypedParameterValue)?.kind ?? nil }
        return kinds.contains { $0 != nil } ? kinds : nil
    }
}
