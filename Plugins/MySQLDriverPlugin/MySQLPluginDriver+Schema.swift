//
//  MySQLPluginDriver+Schema.swift
//  MySQLDriverPlugin
//
//  The column reads, and the rule they share for naming the database they mean.
//

import Foundation
import TableProPluginKit

internal extension MySQLPluginDriver {
    func effectiveSchema(_ schema: String?) -> String {
        MySQLObjectQueries.effectiveSchema(schema, activeDatabase: activeDatabaseName)
    }

    /// The same answer as a literal, for a catalog query that filters on a `TABLE_SCHEMA` column
    /// rather than naming the object.
    func effectiveSchemaLiteral(_ schema: String?) -> String {
        mysqlEscapeStringLiteral(effectiveSchema(schema))
    }

    /// An object name qualified by the database the caller meant.
    ///
    /// A connection with no database selected has nothing to qualify against, and an unqualified
    /// name is then the only form the server will take, so an empty answer falls back to the bare
    /// name rather than rendering an empty qualifier.
    func qualifiedName(_ name: String, schema: String?) -> String {
        MySQLObjectQueries.qualifiedIdentifier(
            schema: effectiveSchema(schema).nilIfEmpty,
            name: name,
            quote: quoteIdentifier
        )
    }

    /// `SHOW TABLE STATUS` is the one statement here that cannot take a dotted name: its grammar
    /// puts the database in a `FROM` clause of its own, and the `WHERE` then matches the bare name.
    func showTableStatus(matching escapedTable: String, schema: String?) -> String {
        let database = effectiveSchema(schema).nilIfEmpty
        let from = database.map { " FROM \(quoteIdentifier($0))" } ?? ""
        return "SHOW TABLE STATUS\(from) WHERE Name = '\(escapedTable)'"
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard !flavor.isDatabend else {
            return try await databendColumns(table: table, schema: schema)
        }
        let result = try await execute(query: "SHOW FULL COLUMNS FROM \(qualifiedName(table, schema: schema))")
        let generationExpressions = try await fetchGenerationExpressions(table: table, schema: schema)

        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let dataType = row[safe: 1]?.asText
            else { return nil }

            let collation = row[safe: 2]?.asText
            let isNullable = (row[safe: 3]?.asText) == "YES"
            let isPrimaryKey = (row[safe: 4]?.asText) == "PRI"
            let rawDefault = row[safe: 5]?.asText
            let extra = row[safe: 6]?.asText
            let comment = row[safe: 8]?.asText

            let charset: String? = {
                guard let coll = collation, coll != "NULL" else { return nil }
                return coll.components(separatedBy: "_").first
            }()

            let upperType = dataType.uppercased()
            let normalizedType = (upperType.hasPrefix("ENUM(") || upperType.hasPrefix("SET("))
                ? dataType : upperType
            let allowedValues = EnumValueParser.parseMySQLEnumOrSet(from: normalizedType)
            let defaultValue = mysqlDefaultValueFromCatalog(
                rawDefault, extra: extra, dataType: normalizedType, quotesLiterals: catalogQuotesDefaults
            )

            return PluginColumnInfo(
                name: name,
                dataType: normalizedType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                extra: extra,
                charset: charset,
                collation: collation == "NULL" ? nil : collation,
                comment: comment?.isEmpty == false ? comment : nil,
                identityKind: mysqlIdentityKind(extra: extra),
                isGenerated: mysqlColumnIsGenerated(extra: extra),
                allowedValues: allowedValues,
                generationExpression: generationExpressions[name],
                generationKind: mysqlGenerationKind(extra: extra)
            )
        }
    }

    /// Merged into the `SHOW FULL COLUMNS` rows by column name alone, so this has to read the same
    /// database that statement did. Reading the session's instead grafts one table's generation
    /// expressions onto another's columns wherever the two databases share a column name.
    private func fetchGenerationExpressions(table: String, schema: String?) async throws -> [String: String] {
        guard MySQLServerVersion.hasGenerationExpression(banner: _serverVersion, flavor: flavor) else {
            return [:]
        }
        let query = """
            SELECT COLUMN_NAME, GENERATION_EXPRESSION
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = \'\(effectiveSchemaLiteral(schema))\'
                AND TABLE_NAME = \'\(mysqlEscapeStringLiteral(table))\'
                AND GENERATION_EXPRESSION <> \'\'
            """
        let result = try await execute(query: query)
        var expressions: [String: String] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText,
                  let expression = row[safe: 1]?.asText?.nilIfEmpty else { continue }
            expressions[name] = expression
        }
        return expressions
    }

    /// MySQL and MariaDB disagree on this catalog: MySQL 8 has no TABLE_NAME on CHECK_CONSTRAINTS
    /// and must join TABLE_CONSTRAINTS to find the owning table, while MariaDB carries TABLE_NAME
    /// directly. Neither exposes the columns a check touches, so `columns` stays empty rather than
    /// being guessed from the expression.
    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        let flavor = self.flavor
        guard !flavor.isDatabend else {
            return try await databendCheckConstraints(table: table, schema: schema)
        }
        guard MySQLServerVersion.hasCheckConstraints(banner: _serverVersion, flavor: flavor) else {
            return []
        }
        guard !flavor.isTiDB else { return try await tidbCheckConstraints(table: table, schema: schema) }
        let database = effectiveSchemaLiteral(schema)
        let safeTable = mysqlEscapeStringLiteral(table)
        let query: String
        if flavor.isMariaDB {
            query = """
                SELECT CONSTRAINT_NAME, CHECK_CLAUSE
                FROM INFORMATION_SCHEMA.CHECK_CONSTRAINTS
                WHERE CONSTRAINT_SCHEMA = \'\(database)\' AND TABLE_NAME = \'\(safeTable)\'
                ORDER BY CONSTRAINT_NAME
                """
        } else {
            query = """
                SELECT cc.CONSTRAINT_NAME, cc.CHECK_CLAUSE
                FROM INFORMATION_SCHEMA.CHECK_CONSTRAINTS cc
                JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                    ON tc.CONSTRAINT_SCHEMA = cc.CONSTRAINT_SCHEMA
                    AND tc.CONSTRAINT_NAME = cc.CONSTRAINT_NAME
                WHERE cc.CONSTRAINT_SCHEMA = \'\(database)\' AND tc.TABLE_NAME = \'\(safeTable)\'
                ORDER BY cc.CONSTRAINT_NAME
                """
        }
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let clause = row[safe: 1]?.asText else { return nil }
            return PluginCheckConstraintInfo(name: name, expression: clause)
        }
    }

    var providesBulkColumnFetch: Bool { true }

    /// `GENERATION_EXPRESSION` is projected here rather than looked up per table, because a caller
    /// that takes the bulk list has to receive what `fetchColumns` would have given it. Without the
    /// column the two reads disagree on generated columns alone, and a schema comparison built on
    /// the bulk read reports a changed generation expression as no difference at all.
    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        guard !flavor.isDatabend else { return try await databendAllColumns(schema: schema) }
        let escapedDb = effectiveSchemaLiteral(schema)
        let hasGenerationExpression = MySQLServerVersion.hasGenerationExpression(
            banner: _serverVersion, flavor: flavor
        )
        let generationProjection = hasGenerationExpression ? "GENERATION_EXPRESSION" : "NULL"
        let query = """
            SELECT
                TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLLATION_NAME,
                IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT,
                \(generationProjection)
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = '\(escapedDb)'
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """

        let result = try await execute(query: query)

        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText,
                  let dataType = row[safe: 2]?.asText
            else { continue }

            let collation = row[safe: 3]?.asText
            let isNullable = (row[safe: 4]?.asText) == "YES"
            let isPrimaryKey = (row[safe: 5]?.asText) == "PRI"
            let rawDefault = row[safe: 6]?.asText
            let extra = row[safe: 7]?.asText
            let comment = row[safe: 8]?.asText

            let charset: String? = {
                guard let coll = collation, coll != "NULL" else { return nil }
                return coll.components(separatedBy: "_").first
            }()

            let upperType = dataType.uppercased()
            let normalizedType = (upperType.hasPrefix("ENUM(") || upperType.hasPrefix("SET("))
                ? dataType : upperType
            let allowedValues = EnumValueParser.parseMySQLEnumOrSet(from: normalizedType)
            let defaultValue = mysqlDefaultValueFromCatalog(
                rawDefault, extra: extra, dataType: normalizedType, quotesLiterals: catalogQuotesDefaults
            )

            let column = PluginColumnInfo(
                name: name,
                dataType: normalizedType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                extra: extra,
                charset: charset,
                collation: collation == "NULL" ? nil : collation,
                comment: comment?.isEmpty == false ? comment : nil,
                identityKind: mysqlIdentityKind(extra: extra),
                isGenerated: mysqlColumnIsGenerated(extra: extra),
                allowedValues: allowedValues,
                generationExpression: row[safe: 9]?.asText?.nilIfEmpty,
                generationKind: mysqlGenerationKind(extra: extra)
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }
}
