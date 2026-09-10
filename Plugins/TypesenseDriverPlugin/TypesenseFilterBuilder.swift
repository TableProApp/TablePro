//
//  TypesenseFilterBuilder.swift
//  TypesenseDriverPlugin
//
//  Translates grid column filters into a Typesense `filter_by` expression.
//

import Foundation
import TableProPluginKit

struct TypesenseFilterSpec: Codable, Equatable {
    let column: String
    let op: String
    let value: String

    /// `BETWEEN`'s upper bound travels on its own so a bound containing a comma is never mistaken
    /// for the separator between the two.
    let secondValue: String?

    init(column: String, op: String, value: String, secondValue: String? = nil) {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
    }

    init(_ filter: PluginQueryFilter) {
        self.init(
            column: filter.column, op: filter.op, value: filter.value, secondValue: filter.secondValue
        )
    }
}

enum TypesenseFilterError: Error, LocalizedError, Equatable {
    case unsupportedOperator(String)
    case comparisonNeedsNumber(column: String, op: String)
    case missingUpperBound(column: String)
    case notANumber(column: String, value: String)
    case notABoolean(column: String, value: String)
    case backtickInValue(column: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOperator(let op):
            return String(
                format: String(localized: "Typesense cannot filter with %@."),
                op
            )
        case .missingUpperBound(let column):
            return String(
                format: String(localized: "BETWEEN on %@ needs an upper bound."),
                column
            )
        case .notANumber(let column, let value):
            return String(
                format: String(localized: "%@ is a numeric field, and %@ is not a number."),
                column, value
            )
        case .notABoolean(let column, let value):
            return String(
                format: String(localized: "%@ is a boolean field, so it matches only true or false, not %@."),
                column, value
            )
        case .comparisonNeedsNumber(let column, let op):
            return String(
                format: String(localized: "Typesense only compares numbers with %@, and %@ is not a numeric field."),
                op, column
            )
        case .backtickInValue(let column):
            return String(
                format: String(localized: "Typesense has no way to escape a backtick in a filter value, so %@ cannot be filtered on this text."),
                column
            )
        }
    }
}

enum TypesenseFilterBuilder {
    /// The data grid's free-text filter row. Its text is a `filter_by` expression the user wrote,
    /// so it goes over verbatim, the way the Elasticsearch driver passes a `query_string` through.
    static let rawColumn = "__RAW__"

    private static let comparisonOperators: [String: String] = [
        ">": ">", ">=": ">=", "<": "<", "<=": "<=",
    ]

    static func specs(from filters: [PluginQueryFilter]) -> [TypesenseFilterSpec] {
        filters.map(TypesenseFilterSpec.init)
    }

    static func expression(
        filters: [TypesenseFilterSpec],
        logicMode: String,
        fields: [String: TypesenseField]
    ) throws -> String? {
        let active = filters.filter { spec in
            spec.column != rawColumn || !spec.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !active.isEmpty else { return nil }

        let clauses = try active.map { try clause(for: $0, fields: fields) }
        guard clauses.count > 1 else { return clauses[0] }

        let joiner = logicMode.uppercased() == "OR" ? " || " : " && "
        return clauses.map { "(\($0))" }.joined(separator: joiner)
    }

    static func clause(for spec: TypesenseFilterSpec, fields: [String: TypesenseField]) throws -> String {
        if spec.column == rawColumn { return spec.value }

        let field = fields[spec.column]
        let column = spec.column
        let value = spec.value

        switch spec.op.uppercased() {
        case "=":
            return "\(column):=\(try literal(value, column: column, field: field))"
        case "!=", "<>":
            return "\(column):!=\(try literal(value, column: column, field: field))"
        case ">", ">=", "<", "<=":
            return try comparison(spec.op.uppercased(), column: column, value: value, field: field)
        case "BETWEEN":
            return try range(column: column, spec: spec, field: field)
        case "IN":
            return "\(column):=[\(try list(value, column: column, field: field))]"
        case "NOT IN":
            return "\(column):!=[\(try list(value, column: column, field: field))]"
        case "CONTAINS":
            return "\(column):\(try textLiteral(value, column: column))"
        case "NOT CONTAINS":
            return "\(column):!\(try textLiteral(value, column: column))"
        case "STARTS WITH":
            return "\(column):\(try textLiteral(value, column: column))*"
        default:
            throw TypesenseFilterError.unsupportedOperator(spec.op.uppercased())
        }
    }

    // MARK: - Clause Shapes

    /// A string field silently matches nothing under `>`, `<`, `>=` and `<=` rather than raising,
    /// so an out-of-range comparison has to be refused here or it reads as an empty table.
    private static func comparison(
        _ op: String,
        column: String,
        value: String,
        field: TypesenseField?
    ) throws -> String {
        guard let symbol = comparisonOperators[op] else {
            throw TypesenseFilterError.unsupportedOperator(op)
        }
        return "\(column):\(symbol)\(try numeric(value, column: column, op: op, field: field))"
    }

    /// A Typesense range is inclusive at both ends, which is what BETWEEN means.
    private static func range(column: String, spec: TypesenseFilterSpec, field: TypesenseField?) throws -> String {
        guard let upperBound = spec.secondValue, !upperBound.isEmpty else {
            throw TypesenseFilterError.missingUpperBound(column: column)
        }
        let lower = try numeric(spec.value, column: column, op: "BETWEEN", field: field)
        let upper = try numeric(upperBound, column: column, op: "BETWEEN", field: field)
        return "\(column):[\(lower)..\(upper)]"
    }

    private static func list(_ value: String, column: String, field: TypesenseField?) throws -> String {
        try value
            .split(separator: ",")
            .map { try literal($0.trimmingCharacters(in: .whitespaces), column: column, field: field) }
            .joined(separator: ",")
    }

    // MARK: - Values

    /// Typesense rejects a backticked literal on a numeric or boolean field ("Numerical field has
    /// an invalid comparator"), and needs one on a string field carrying a space or an operator.
    /// The field's declared type is what decides, so an unknown field is quoted as text.
    ///
    /// The unquoted branches carry no delimiter of their own, so each one has to prove the value is
    /// the literal it claims to be. Without that, `year:=1900 || year:>0` reaches the server as
    /// filter syntax, and the field type that picks the branch is declared by the server.
    static func literal(_ value: String, column: String, field: TypesenseField?) throws -> String {
        guard let field else { return try textLiteral(value, column: column) }
        if field.isNumeric {
            guard Double(value) != nil else {
                throw TypesenseFilterError.notANumber(column: column, value: value)
            }
            return value
        }
        if field.isBoolean {
            let lowered = value.lowercased()
            guard lowered == "true" || lowered == "false" else {
                throw TypesenseFilterError.notABoolean(column: column, value: value)
            }
            return lowered
        }
        return try textLiteral(value, column: column)
    }

    /// Backticks are Typesense's only quoting mechanism and it offers no escape for one inside a
    /// value: a backtick ends the literal, and everything after it is parsed as filter syntax.
    /// Measured on 29.0, ``tag:=`odd` || year:>0`` matched every document in the collection.
    static func textLiteral(_ value: String, column: String) throws -> String {
        guard !value.contains("`") else {
            throw TypesenseFilterError.backtickInValue(column: column)
        }
        return "`\(value)`"
    }

    private static func numeric(
        _ value: String,
        column: String,
        op: String,
        field: TypesenseField?
    ) throws -> String {
        if let field, !field.isNumeric {
            throw TypesenseFilterError.comparisonNeedsNumber(column: column, op: op)
        }
        guard Double(value) != nil else {
            throw TypesenseFilterError.comparisonNeedsNumber(column: column, op: op)
        }
        return value
    }
}
