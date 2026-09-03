//
//  PostgreSQLTypeDefinition.swift
//  PostgreSQLDriverPlugin
//
//  PostgreSQL has no pg_get_typedef, so a type's CREATE statement is rebuilt from the catalog row
//  the listing already read. Pure, so the shape of every statement is pinned by a test.
//

import Foundation
import TableProPluginKit

public struct PostgreSQLDomainConstraint: Sendable, Equatable {
    public let name: String
    public let definition: String

    public init(name: String, definition: String) {
        self.name = name
        self.definition = definition
    }
}

public struct PostgreSQLUserDefinedTypeRecord: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case enumeration = "e"
        case composite = "c"
        case domain = "d"
        case range = "r"
    }

    public let identity: String
    public let name: String
    public let schema: String
    public let kind: Kind
    public let owner: String?
    public let comment: String?
    public let enumLabels: [String]
    public let fields: [PluginUserDefinedTypeField]
    public let baseType: String?

    /// A domain's collation, only when it differs from the base type's own. Already quoted.
    public let collation: String?
    public let isNotNull: Bool
    public let defaultValue: String?
    public let constraints: [PostgreSQLDomainConstraint]
    public let rangeSubtype: String?
    public let rangeCanonical: String?
    public let rangeSubtypeDiff: String?

    /// The subtype's operator class, qualified and quoted, only when it is not the default one.
    public let rangeOpclass: String?

    /// The range's collation, only when it differs from the subtype's own.
    public let rangeCollation: String?

    /// The companion multirange's qualified name, on PostgreSQL 14 and later.
    public let rangeMultirange: String?

    /// The engine's own qualified, quoted spelling of the type, for a column definition.
    public let spelling: String?

    public init(
        identity: String,
        name: String,
        schema: String,
        kind: Kind,
        owner: String? = nil,
        comment: String? = nil,
        enumLabels: [String] = [],
        fields: [PluginUserDefinedTypeField] = [],
        baseType: String? = nil,
        collation: String? = nil,
        isNotNull: Bool = false,
        defaultValue: String? = nil,
        constraints: [PostgreSQLDomainConstraint] = [],
        rangeSubtype: String? = nil,
        rangeCanonical: String? = nil,
        rangeSubtypeDiff: String? = nil,
        rangeOpclass: String? = nil,
        rangeCollation: String? = nil,
        rangeMultirange: String? = nil,
        spelling: String? = nil
    ) {
        self.identity = identity
        self.name = name
        self.schema = schema
        self.kind = kind
        self.owner = owner
        self.comment = comment
        self.enumLabels = enumLabels
        self.fields = fields
        self.baseType = baseType
        self.collation = collation
        self.isNotNull = isNotNull
        self.defaultValue = defaultValue
        self.constraints = constraints
        self.rangeSubtype = rangeSubtype
        self.rangeCanonical = rangeCanonical
        self.rangeSubtypeDiff = rangeSubtypeDiff
        self.rangeOpclass = rangeOpclass
        self.rangeCollation = rangeCollation
        self.rangeMultirange = rangeMultirange
        self.spelling = spelling
    }
}

public enum PostgreSQLTypeDefinition {
    /// The projection `PostgreSQLObjectQueries.userDefinedTypeList` selects, in order. The parser
    /// reads by these positions, so the query and the parser cannot drift apart silently.
    public enum Column: Int, CaseIterable {
        case identity
        case name
        case schema
        case kind
        case owner
        case comment
        case enumLabels
        case fields
        case baseType
        case collation
        case isNotNull
        case defaultValue
        case constraints
        case rangeSubtype
        case rangeCanonical
        case rangeSubtypeDiff
        case rangeOpclass
        case rangeCollation
        case rangeMultirange
        case spelling
    }

    public static func record(from row: [PluginCellValue]) -> PostgreSQLUserDefinedTypeRecord? {
        guard let identity = text(row, .identity),
              let name = text(row, .name),
              let schema = text(row, .schema),
              let kind = text(row, .kind).flatMap(PostgreSQLUserDefinedTypeRecord.Kind.init(rawValue:))
        else { return nil }
        return PostgreSQLUserDefinedTypeRecord(
            identity: identity,
            name: name,
            schema: schema,
            kind: kind,
            owner: text(row, .owner),
            comment: text(row, .comment),
            enumLabels: jsonStrings(text(row, .enumLabels)),
            fields: jsonObjects(text(row, .fields)).compactMap { object in
                guard let name = object["name"], let type = object["type"] else { return nil }
                return PluginUserDefinedTypeField(name: name, type: type, collation: object["collation"])
            },
            baseType: text(row, .baseType),
            collation: text(row, .collation),
            isNotNull: text(row, .isNotNull) == "t" || text(row, .isNotNull) == "true",
            defaultValue: text(row, .defaultValue),
            constraints: jsonObjects(text(row, .constraints)).compactMap { object in
                guard let name = object["name"], let definition = object["definition"] else { return nil }
                return PostgreSQLDomainConstraint(name: name, definition: definition)
            },
            rangeSubtype: text(row, .rangeSubtype),
            rangeCanonical: text(row, .rangeCanonical),
            rangeSubtypeDiff: text(row, .rangeSubtypeDiff),
            rangeOpclass: text(row, .rangeOpclass),
            rangeCollation: text(row, .rangeCollation),
            rangeMultirange: text(row, .rangeMultirange),
            spelling: text(row, .spelling)
        )
    }

    public static func info(from record: PostgreSQLUserDefinedTypeRecord) -> PluginUserDefinedTypeInfo {
        PluginUserDefinedTypeInfo(
            name: record.name,
            kind: kind(of: record),
            schema: record.schema,
            identity: record.identity,
            enumLabels: record.enumLabels,
            fields: record.fields,
            baseType: record.baseType ?? record.rangeSubtype,
            columnTypeSpelling: record.spelling,
            definition: ddl(for: record),
            attributes: attributes(of: record)
        )
    }

    /// What PostgreSQL names the companion multirange when the creator did not: the last `range`
    /// in the name becomes `multirange`, and a name without one gains `_multirange`.
    public static func defaultMultirangeName(for rangeName: String) -> String {
        guard let range = rangeName.range(of: "range", options: .backwards) else {
            return rangeName + "_multirange"
        }
        return rangeName.replacingCharacters(in: range, with: "multirange")
    }

    public static func ddl(for record: PostgreSQLUserDefinedTypeRecord) -> String {
        let qualifiedName = qualifiedName(of: record)
        switch record.kind {
        case .enumeration:
            let labels = record.enumLabels
                .map { "    \(PostgreSQLObjectQueries.quoteLiteral($0))" }
                .joined(separator: ",\n")
            return "CREATE TYPE \(qualifiedName) AS ENUM (\n\(labels)\n);"
        case .composite:
            let fields = record.fields
                .map { field -> String in
                    var line = "    \(PostgreSQLObjectQueries.quoteIdentifier(field.name)) \(field.type)"
                    if let collation = field.collation, !collation.isEmpty { line += " COLLATE \(collation)" }
                    return line
                }
                .joined(separator: ",\n")
            return "CREATE TYPE \(qualifiedName) AS (\n\(fields)\n);"
        case .domain:
            return domainDDL(for: record, qualifiedName: qualifiedName)
        case .range:
            return rangeDDL(for: record, qualifiedName: qualifiedName)
        }
    }

    private static func domainDDL(for record: PostgreSQLUserDefinedTypeRecord, qualifiedName: String) -> String {
        var clauses: [String] = []
        if let defaultValue = record.defaultValue, !defaultValue.isEmpty {
            clauses.append("DEFAULT \(defaultValue)")
        }
        if record.isNotNull {
            clauses.append("NOT NULL")
        }
        clauses += record.constraints.map {
            "CONSTRAINT \(PostgreSQLObjectQueries.quoteIdentifier($0.name)) \($0.definition)"
        }
        var head = "CREATE DOMAIN \(qualifiedName) AS \(record.baseType ?? "")"
        if let collation = record.collation, !collation.isEmpty {
            head += " COLLATE \(collation)"
        }
        guard !clauses.isEmpty else { return "\(head);" }
        return head + "\n" + clauses.map { "    \($0)" }.joined(separator: "\n") + ";"
    }

    private static func rangeDDL(for record: PostgreSQLUserDefinedTypeRecord, qualifiedName: String) -> String {
        var options: [String] = ["subtype = \(record.rangeSubtype ?? "")"]
        if let opclass = record.rangeOpclass, !opclass.isEmpty {
            options.append("subtype_opclass = \(opclass)")
        }
        if let collation = record.rangeCollation, !collation.isEmpty {
            options.append("collation = \(collation)")
        }
        if let canonical = record.rangeCanonical, !canonical.isEmpty {
            options.append("canonical = \(canonical)")
        }
        if let subtypeDiff = record.rangeSubtypeDiff, !subtypeDiff.isEmpty {
            options.append("subtype_diff = \(subtypeDiff)")
        }
        let defaultMultirange = PostgreSQLObjectQueries.qualifiedName(
            schema: record.schema, name: defaultMultirangeName(for: record.name)
        )
        if let multirange = record.rangeMultirange, !multirange.isEmpty,
           multirange != defaultMultirange, multirange != unquoted(defaultMultirange) {
            options.append("multirange_type_name = \(multirange)")
        }
        let body = options.map { "    \($0)" }.joined(separator: ",\n")
        return "CREATE TYPE \(qualifiedName) AS RANGE (\n\(body)\n);"
    }

    private static func kind(of record: PostgreSQLUserDefinedTypeRecord) -> PluginUserDefinedTypeKind {
        switch record.kind {
        case .enumeration: return .enumeration
        case .composite: return .composite
        case .domain: return .domain
        case .range: return .range
        }
    }

    private static func attributes(of record: PostgreSQLUserDefinedTypeRecord) -> [PluginObjectAttribute] {
        var attributes: [PluginObjectAttribute] = []
        if let baseType = record.baseType, !baseType.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Base Type", value: baseType))
        }
        if let subtype = record.rangeSubtype, !subtype.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Subtype", value: subtype))
        }
        if let owner = record.owner, !owner.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Owner", value: owner))
        }
        if let comment = record.comment, !comment.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Comment", value: comment))
        }
        return attributes
    }

    /// `quote_ident` on the server leaves a plain lower-case name bare, so the catalog's spelling
    /// of the default multirange has to be compared in both forms.
    private static func unquoted(_ qualifiedName: String) -> String {
        qualifiedName.replacingOccurrences(of: "\"", with: "")
    }

    private static func qualifiedName(of record: PostgreSQLUserDefinedTypeRecord) -> String {
        "\(PostgreSQLObjectQueries.quoteIdentifier(record.schema)).\(PostgreSQLObjectQueries.quoteIdentifier(record.name))"
    }

    private static func text(_ row: [PluginCellValue], _ column: Column) -> String? {
        guard column.rawValue < row.count, let value = row[column.rawValue].asText, !value.isEmpty else { return nil }
        return value
    }

    private static func jsonStrings(_ json: String?) -> [String] {
        guard let data = json?.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return array.compactMap { $0 as? String }
    }

    private static func jsonObjects(_ json: String?) -> [[String: String]] {
        guard let data = json?.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.map { object in
            object.compactMapValues { $0 as? String }
        }
    }
}
