//
//  PostgreSQLTypeStatements.swift
//  PostgreSQLDriverPlugin
//
//  The DDL that creates, alters and drops enums, composites, domains and ranges. Pure, so every
//  statement is pinned by a test and run against each server by
//  `apple/scripts/probes/check-postgres-type-editing.sh`.
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

nonisolated public enum PostgreSQLTypeStatements {
    /// ALTER TYPE renames and comments a domain too, but ALTER DOMAIN is the form the docs give and
    /// the only one the domain clauses parse under.
    static func keyword(for kind: PluginUserDefinedTypeKind) -> String {
        kind == .domain ? "DOMAIN" : "TYPE"
    }

    static let editableKinds: Set<PluginUserDefinedTypeKind> = [.enumeration, .composite, .domain, .range]

    public static func create(_ definition: PluginUserDefinedTypeDefinition, schema: String) -> [String]? {
        let name = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: definition.name)
        let create: String
        switch definition.kind {
        case .enumeration:
            create = "CREATE TYPE \(name) AS ENUM \(list(definition.enumLabels.map(PostgreSQLObjectQueries.quoteLiteral)))"
        case .composite:
            create = "CREATE TYPE \(name) AS \(list(definition.fields.map(fieldClause)))"
        case .domain:
            guard let baseType = trimmed(definition.baseType) else { return nil }
            var clauses: [String] = []
            if let defaultValue = trimmed(definition.defaultValue) {
                clauses.append("DEFAULT \(defaultValue)")
            }
            if definition.isNotNull {
                clauses.append("NOT NULL")
            }
            clauses += definition.checks.map(checkClause)
            create = (["CREATE DOMAIN \(name) AS \(baseType)"] + clauses).joined(separator: "\n    ")
        default:
            return nil
        }
        guard let comment = trimmed(definition.comment) else { return [create] }
        return [create, commentStatement(kind: definition.kind, name: name, comment: comment)]
    }

    public static func alter(
        type: PluginUserDefinedTypeInfo,
        schema: String,
        change: PluginUserDefinedTypeChange,
        capabilities: PostgreSQLCapabilities
    ) -> [String]? {
        guard editableKinds.contains(type.kind) else { return nil }
        let name = PostgreSQLObjectQueries.qualifiedName(schema: schema, name: type.name)
        let alter = "ALTER \(keyword(for: type.kind)) \(name)"
        switch change {
        case .rename(let newName):
            return ["\(alter) RENAME TO \(PostgreSQLObjectQueries.quoteIdentifier(newName))"]
        case .setComment(let comment):
            return [commentStatement(kind: type.kind, name: name, comment: trimmed(comment))]
        case .addEnumLabel(let label, let placement):
            guard type.kind == .enumeration else { return nil }
            if placement != nil, !capabilities.hasEnumLabelPlacement { return nil }
            return [PostgreSQLObjectQueries.addEnumLabel(
                schema: schema,
                name: type.name,
                label: label,
                placement: placement,
                ifNotExists: capabilities.hasEnumAddValueIfNotExists
            )]
        case .renameEnumLabel(let oldLabel, let newLabel):
            guard type.kind == .enumeration, capabilities.hasRenameEnumValue else { return nil }
            return [PostgreSQLObjectQueries.renameEnumLabel(schema: schema, name: type.name, from: oldLabel, to: newLabel)]
        case .setDefault(let value):
            guard type.kind == .domain else { return nil }
            guard let value = trimmed(value) else { return ["\(alter) DROP DEFAULT"] }
            return ["\(alter) SET DEFAULT \(value)"]
        case .setNotNull(let isNotNull):
            guard type.kind == .domain else { return nil }
            return ["\(alter) \(isNotNull ? "SET" : "DROP") NOT NULL"]
        case .addCheck(let check, let validatesExistingValues):
            guard type.kind == .domain else { return nil }
            guard validatesExistingValues else {
                guard capabilities.hasDomainConstraintValidation else { return nil }
                return ["\(alter) ADD \(checkClause(check)) NOT VALID"]
            }
            return ["\(alter) ADD \(checkClause(check))"]
        case .dropConstraint(let constraint):
            guard type.kind == .domain else { return nil }
            return ["\(alter) DROP CONSTRAINT \(PostgreSQLObjectQueries.quoteIdentifier(constraint))"]
        case .validateConstraint(let constraint):
            guard type.kind == .domain, capabilities.hasDomainConstraintValidation else { return nil }
            return ["\(alter) VALIDATE CONSTRAINT \(PostgreSQLObjectQueries.quoteIdentifier(constraint))"]
        case .addField(let field):
            guard type.kind == .composite, capabilities.hasCompositeAttributeAlteration else { return nil }
            return ["\(alter) ADD ATTRIBUTE \(fieldClause(field))"]
        case .dropField(let field):
            guard type.kind == .composite, capabilities.hasCompositeAttributeAlteration else { return nil }
            return ["\(alter) DROP ATTRIBUTE \(PostgreSQLObjectQueries.quoteIdentifier(field))"]
        case .renameField(let oldName, let newName):
            guard type.kind == .composite, capabilities.hasCompositeAttributeAlteration else { return nil }
            return [
                "\(alter) RENAME ATTRIBUTE \(PostgreSQLObjectQueries.quoteIdentifier(oldName)) "
                    + "TO \(PostgreSQLObjectQueries.quoteIdentifier(newName))"
            ]
        case .changeFieldType(let field, let newType):
            guard type.kind == .composite, capabilities.hasCompositeAttributeAlteration else { return nil }
            return ["\(alter) ALTER ATTRIBUTE \(PostgreSQLObjectQueries.quoteIdentifier(field)) SET DATA TYPE \(newType)"]
        @unknown default:
            return nil
        }
    }

    /// Measured: PostgreSQL 11 refuses ADD VALUE inside BEGIN; 13 and 18 run it there, and a label
    /// added in the block can anchor another addition and be renamed before COMMIT.
    public static func runsOutsideTransaction(_ change: PluginUserDefinedTypeChange, capabilities: PostgreSQLCapabilities) -> Bool {
        guard case .addEnumLabel = change else { return false }
        return !capabilities.hasEnumAddValueInTransaction
    }

    public static func drop(schema: String, name: String, kind: PluginUserDefinedTypeKind, cascade: Bool) -> String {
        let statement = PostgreSQLObjectQueries.dropType(schema: schema, name: name, kind: kind)
        return cascade ? statement + " CASCADE" : statement
    }

    private static func commentStatement(kind: PluginUserDefinedTypeKind, name: String, comment: String?) -> String {
        let value = comment.map(PostgreSQLObjectQueries.quoteLiteral) ?? "NULL"
        return "COMMENT ON \(keyword(for: kind)) \(name) IS \(value)"
    }

    private static func fieldClause(_ field: PluginUserDefinedTypeField) -> String {
        var clause = "\(PostgreSQLObjectQueries.quoteIdentifier(field.name)) \(field.type)"
        if let collation = trimmed(field.collation) {
            clause += " COLLATE \(collation)"
        }
        return clause
    }

    private static func checkClause(_ check: PluginUserDefinedTypeCheck) -> String {
        let body = "CHECK (\(check.expression))"
        guard let name = trimmed(check.name) else { return body }
        return "CONSTRAINT \(PostgreSQLObjectQueries.quoteIdentifier(name)) \(body)"
    }

    /// `AS ENUM ()` and `AS ()` both parse: an empty enum or composite is a valid type.
    private static func list(_ items: [String]) -> String {
        guard !items.isEmpty else { return "()" }
        return "(\n" + items.map { "    \($0)" }.joined(separator: ",\n") + "\n)"
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
