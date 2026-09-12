//
//  PostgreSQLVersionedStatements.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal struct PostgreSQLSessionFacts: Sendable, Equatable {
    static let probeQuery = "SELECT pg_catalog.current_database(), pg_catalog.current_setting('server_version_num')"
    static let unknown = PostgreSQLSessionFacts(database: nil, serverVersion: nil)

    let database: String?
    let serverVersion: Int32?

    init(database: String?, serverVersion: Int32?) {
        self.database = database
        self.serverVersion = serverVersion
    }

    init(probeRow row: [String?]) {
        let database = row.first.flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        let versionText = row.count > 1 ? row[1]?.trimmingCharacters(in: .whitespaces) : nil
        let version = versionText.flatMap { Int32($0) }.flatMap { $0 > 0 ? $0 : nil }
        self.init(database: database, serverVersion: version)
    }

    func resolvedServerVersion(reported: Int32) -> Int32 {
        guard reported <= 0 else { return reported }
        return serverVersion ?? 0
    }
}

internal enum PostgreSQLVersionedStatements {
    static let postgreSQLIndexMethods: Set<String> = ["BTREE", "HASH", "GIN", "GIST", "BRIN"]
    static let mySQLOnlyIndexTypes: Set<String> = ["FULLTEXT", "SPATIAL"]

    static func createSchema(_ name: String, capabilities: PostgreSQLCapabilities) -> String {
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(name)
        guard !capabilities.hasCreateSchemaIfNotExists else {
            return "CREATE SCHEMA IF NOT EXISTS \(identifier)"
        }
        let nameLiteral = PostgreSQLObjectQueries.quoteLiteral(name)
        let createLiteral = PostgreSQLObjectQueries.quoteLiteral("CREATE SCHEMA \(identifier)")
        let body = "BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = \(nameLiteral)) "
            + "THEN EXECUTE \(createLiteral); END IF; END"
        let tag = dollarQuoteTag(avoiding: body)
        return "DO \(tag) \(body) \(tag)"
    }

    static func reindexDatabase(currentDatabase: String?, capabilities: PostgreSQLCapabilities) -> String? {
        guard !capabilities.hasUnnamedReindexDatabase else { return "REINDEX DATABASE CONCURRENTLY" }
        guard let currentDatabase, !currentDatabase.isEmpty else { return nil }
        let identifier = PostgreSQLObjectQueries.quoteIdentifier(currentDatabase)
        guard capabilities.hasReindexConcurrently else { return "REINDEX DATABASE \(identifier)" }
        return "REINDEX DATABASE CONCURRENTLY \(identifier)"
    }

    static func triggerTemplate(
        qualifiedTable: String,
        qualifiedFunction: String,
        capabilities: PostgreSQLCapabilities
    ) -> String {
        let trigger = PostgreSQLObjectQueries.quoteIdentifier("trigger_name")
        let executeKeyword = capabilities.hasExecuteFunctionTriggerSyntax ? "EXECUTE FUNCTION" : "EXECUTE PROCEDURE"
        let createKeyword = capabilities.hasCreateOrReplaceTrigger ? "CREATE OR REPLACE TRIGGER" : "CREATE TRIGGER"
        return """
            CREATE OR REPLACE FUNCTION \(qualifiedFunction)()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $function$
            BEGIN
                -- NEW.updated_at := now();
                RETURN NEW;
            END;
            $function$;

            \(createKeyword) \(trigger)
                BEFORE INSERT ON \(qualifiedTable)
                FOR EACH ROW
                \(executeKeyword) \(qualifiedFunction)();
            """
    }

    static func editableTriggerDefinition(
        functionDefinition: String,
        triggerDefinition: String,
        dropStatement: String?,
        capabilities: PostgreSQLCapabilities
    ) -> String {
        guard capabilities.hasCreateOrReplaceTrigger else {
            return "\(functionDefinition);\n\n\(triggerDefinition);"
        }
        guard triggerDefinition.range(of: "CREATE CONSTRAINT TRIGGER", options: .caseInsensitive) == nil else {
            return "\(functionDefinition);\n\n\(dropStatement ?? "");\n\(triggerDefinition);"
        }
        let replaceable = triggerDefinition.replacingOccurrences(
            of: "CREATE TRIGGER ",
            with: "CREATE OR REPLACE TRIGGER "
        )
        return "\(functionDefinition);\n\n\(replaceable);"
    }

    static func renameConstraint(
        qualifiedTable: String,
        from oldName: String,
        to newName: String,
        capabilities: PostgreSQLCapabilities
    ) -> String? {
        guard capabilities.hasRenameConstraint, !oldName.isEmpty, !newName.isEmpty else { return nil }
        return "ALTER TABLE \(qualifiedTable) RENAME CONSTRAINT "
            + "\(PostgreSQLObjectQueries.quoteIdentifier(oldName)) TO \(PostgreSQLObjectQueries.quoteIdentifier(newName))"
    }

    static func copyRows(
        into qualifiedTable: String,
        from stagingTable: String,
        columnList: String,
        capabilities: PostgreSQLCapabilities
    ) -> String {
        let overriding = capabilities.hasIdentityColumns ? " OVERRIDING SYSTEM VALUE" : ""
        return "INSERT INTO \(qualifiedTable) (\(columnList))\(overriding) SELECT \(columnList) FROM \(stagingTable)"
    }

    static func refusal(for operation: PluginSchemaOperation, capabilities: PostgreSQLCapabilities) -> String? {
        switch operation {
        case .addColumn(let column):
            return columnRefusal(column, capabilities: capabilities)
        case .addIndex(let index):
            return indexRefusal(index, capabilities: capabilities)
        case .renameCheckConstraint:
            guard !capabilities.hasRenameConstraint else { return nil }
            return String(localized: "Renaming a check constraint needs PostgreSQL 9.2 or later.")
        @unknown default:
            return nil
        }
    }

    static func refusal(for definition: PluginCreateTableDefinition, capabilities: PostgreSQLCapabilities) -> String? {
        let operations = definition.columns.map(PluginSchemaOperation.addColumn)
            + definition.indexes.map(PluginSchemaOperation.addIndex)
        return operations.lazy.compactMap { refusal(for: $0, capabilities: capabilities) }.first
    }

    static func columnRefusal(_ column: PluginColumnDefinition, capabilities: PostgreSQLCapabilities) -> String? {
        guard column.isGenerated, !capabilities.hasGeneratedColumns else { return nil }
        return String(
            format: String(localized: "Column %@ is a generated column, which needs PostgreSQL 12 or later."),
            column.name
        )
    }

    static func indexRefusal(_ index: PluginIndexDefinition, capabilities: PostgreSQLCapabilities) -> String? {
        guard let type = index.indexType?.uppercased(), !type.isEmpty else { return nil }
        if mySQLOnlyIndexTypes.contains(type) {
            return String(format: String(localized: "PostgreSQL has no %@ index type."), type)
        }
        guard type == "BRIN", !capabilities.hasBrinIndexes else { return nil }
        return String(localized: "BRIN indexes need PostgreSQL 9.5 or later.")
    }

    static func unsupportedStructureColumnFields(capabilities: PostgreSQLCapabilities) -> Set<StructureColumnField> {
        capabilities.hasGeneratedColumns ? [] : [.generated, .generationExpression]
    }

    static func unsupportedIndexTypes(capabilities: PostgreSQLCapabilities) -> Set<String> {
        capabilities.hasBrinIndexes ? mySQLOnlyIndexTypes : mySQLOnlyIndexTypes.union(["BRIN"])
    }

    static func roleAttributes(capabilities: PostgreSQLCapabilities) -> Set<PostgreSQLRoleAttribute> {
        Set(PostgreSQLRoleAttribute.allCases.filter { $0 != .bypassrls || capabilities.hasBypassRLS })
    }

    private static func dollarQuoteTag(avoiding body: String) -> String {
        var label = "tablepro"
        while body.contains("$\(label)$") {
            label += "_"
        }
        return "$\(label)$"
    }
}
