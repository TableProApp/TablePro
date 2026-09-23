//
//  MySQLPluginDriver+Schema.swift
//  MySQLDriverPlugin
//
//  The column reads, and the rule they share for naming the database they mean.
//

import Foundation
import os
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
        guard !flavor.isOceanBase else {
            let columnsByTable = try await informationSchemaColumns(schema: schema, table: table)
            return columnsByTable[table] ?? (columnsByTable.count == 1 ? columnsByTable.values.first ?? [] : [])
        }
        let result = try await execute(query: "SHOW FULL COLUMNS FROM \(qualifiedName(table, schema: schema))")
        let catalogDetails = try await fetchCatalogColumnDetails(table: table, schema: schema)
        let createTableDefaults = try await createTableDefaults(
            table: table, schema: schema, showRows: result.rows, catalogDetails: catalogDetails
        )

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
            let detail = catalogDetails[name]
            let defaultValue = mysqlShowColumnsDefault(
                rawDefault,
                catalog: detail?.catalogDefault,
                createTable: createTableDefaults,
                column: name,
                extra: extra,
                dataType: normalizedType,
                isNullable: isNullable
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
                generationExpression: detail?.generationExpression,
                generationKind: mysqlGenerationKind(extra: extra)
            )
        }
    }

    /// What `INFORMATION_SCHEMA.COLUMNS` says about a table's columns that `SHOW FULL COLUMNS` cannot:
    /// a generated column's expression, and on MariaDB from 10.2.7 the default in its quoted form.
    /// MariaDB's `SHOW FULL COLUMNS` reports `'abc'` as `abc` and an expression with no marker, so
    /// only this read tells a string from an expression there.
    ///
    /// `SHOW FULL COLUMNS` stays the primary read rather than giving way to this one: a MySQL-protocol
    /// proxy answers `SHOW` truthfully while answering the catalog with nothing or an error (see
    /// `MySQLPluginDriver+CatalogFallback.swift`), and a column list read from the catalog alone would
    /// come back empty there.
    ///
    /// Merged into the `SHOW FULL COLUMNS` rows by column name alone, so this has to read the same
    /// database that statement did. Reading the session's instead grafts one table's details onto
    /// another's columns wherever the two databases share a column name.
    ///
    /// Skipped entirely where the catalog is known not to describe the database: it would answer
    /// nothing there, and the degraded whole-schema read runs this once per table.
    ///
    /// A catalog that refuses is not this read's to report either. One refused read does not mark a
    /// database blind, so a proxy that answers `ERROR 1064` rather than answering nothing still
    /// reaches this statement, and a throw here would take the whole `SHOW FULL COLUMNS` answer with
    /// it. It degrades to no details instead, which is what the blind path returns anyway, and every
    /// default then reads from `SHOW FULL COLUMNS` in its bare form.
    private func fetchCatalogColumnDetails(
        table: String,
        schema: String?
    ) async throws -> [String: MySQLCatalogColumnDetail] {
        guard catalogVisibility.visibility(of: effectiveSchema(schema)) != .blind else { return [:] }
        let identity = serverIdentity
        let readsGeneration = MySQLServerVersion.hasGenerationExpression(
            banner: identity.banner, flavor: identity.flavor
        )
        let readsDefault = MySQLServerVersion.quotesColumnDefault(banner: identity.banner, flavor: identity.flavor)
        guard readsGeneration || readsDefault else { return [:] }
        let generationProjection = readsGeneration ? "GENERATION_EXPRESSION" : "NULL"
        let defaultProjection = readsDefault ? "COLUMN_DEFAULT" : "NULL"
        let generatedOnly = readsDefault ? "" : " AND GENERATION_EXPRESSION <> \'\'"
        let query = """
            SELECT COLUMN_NAME, \(generationProjection), \(defaultProjection)
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = \'\(effectiveSchemaLiteral(schema))\'
                AND TABLE_NAME = \'\(mysqlEscapeStringLiteral(table))\'\(generatedOnly)
            """
        do {
            let result = try await execute(ownStatement: query)
            var details: [String: MySQLCatalogColumnDetail] = [:]
            for row in result.rows {
                guard let name = row[safe: 0]?.asText else { continue }
                details[name] = MySQLCatalogColumnDetail(
                    generationExpression: row[safe: 1]?.asText?.nilIfEmpty,
                    catalogDefault: readsDefault ? .quoted(row[safe: 2]?.asText) : nil
                )
            }
            return details
        } catch let error as MariaDBPluginError
            where MySQLCatalogVisibilityRule.settlesBlindness(code: error.code) {
            Self.logger.warning(
                "column catalog read refused code=\(error.code, privacy: .public) message=\(error.message)"
            )
            return [:]
        }
    }

    /// The defaults `SHOW CREATE TABLE` states, for the columns whose catalog answer cannot recreate
    /// them, or nil when no column needs it.
    ///
    /// Two cases need it. A MariaDB whose catalog did not answer in its quoted form, a server before
    /// 10.2.7 or one whose catalog is blind or refused: its `SHOW FULL COLUMNS` reports the expression
    /// `uuid()` and the string `'uuid()'` alike, so the bare form turns an expression into a constant
    /// the next time the column is written. And a MySQL expression default holding non-ASCII text,
    /// which the catalog keeps encoded twice.
    /// `SHOW CREATE TABLE` spells both exactly, and a proxy answers it as truthfully as it answers
    /// `SHOW FULL COLUMNS`.
    private func createTableDefaults(
        table: String,
        schema: String?,
        showRows: [[PluginCellValue]],
        catalogDetails: [String: MySQLCatalogColumnDetail]
    ) async throws -> MySQLCreateTableDefaults? {
        guard let scope = createTableDefaultsScope(showRows: showRows, catalogDetails: catalogDetails),
              let clauses = try await createTableDefaultClauses(table: table, schema: schema)
        else { return nil }
        return MySQLCreateTableDefaults(clauses: clauses, scope: scope)
    }

    /// The whole-schema read's counterpart of `createTableDefaults`: one `SHOW CREATE TABLE` for each
    /// table holding a default its catalog row cannot recreate, and none for the rest. The rows are
    /// `INFORMATION_SCHEMA.COLUMNS` rows, which on a MariaDB from 10.2.7 are already exact.
    private func createTableDefaultsByTable(
        forCatalogRows rows: [[PluginCellValue]],
        schema: String?
    ) async throws -> [String: MySQLCreateTableDefaults] {
        let identity = serverIdentity
        guard !identity.flavor.isOceanBase else { return [:] }
        let scope: MySQLCreateTableDefaults.Scope
        let needsCreateTable: ([PluginCellValue]) -> Bool
        if identity.flavor.isMariaDB {
            guard MySQLServerVersion.mariaDBDefaultsCanBeExpressions(banner: identity.banner, flavor: identity.flavor),
                  !MySQLServerVersion.quotesColumnDefault(banner: identity.banner, flavor: identity.flavor)
            else { return [:] }
            scope = .everyColumn
            needsCreateTable = { row in
                mariaDBBareDefaultMayBeExpression(row[safe: 6]?.asText, dataType: row[safe: 2]?.asText ?? "")
            }
        } else {
            scope = .expressionDefaults
            needsCreateTable = { row in
                mysqlExpressionDefaultNeedsCreateTable(
                    row[safe: 6]?.asText, extra: row[safe: 7]?.asText, dataType: row[safe: 2]?.asText ?? ""
                )
            }
        }
        let tables = Set(rows.filter(needsCreateTable).compactMap { $0[safe: 0]?.asText })
        var defaults: [String: MySQLCreateTableDefaults] = [:]
        for table in tables.sorted() {
            guard let clauses = try await createTableDefaultClauses(table: table, schema: schema) else { continue }
            defaults[table] = MySQLCreateTableDefaults(clauses: clauses, scope: scope)
        }
        return defaults
    }

    /// Nil when the statement is refused, or does not describe a table: a view's leaves its columns on
    /// the catalog's answer.
    private func createTableDefaultClauses(table: String, schema: String?) async throws -> [String: String]? {
        do {
            let result = try await execute(query: "SHOW CREATE TABLE \(qualifiedName(table, schema: schema))")
            guard let createTable = result.rows.first?[safe: 1]?.asText else { return nil }
            return MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: createTable)
        } catch let error as MariaDBPluginError
            where MySQLCatalogVisibilityRule.settlesBlindness(code: error.code) {
            Self.logger.warning(
                "create table default read refused code=\(error.code, privacy: .public) message=\(error.message)"
            )
            return nil
        }
    }

    private func createTableDefaultsScope(
        showRows: [[PluginCellValue]],
        catalogDetails: [String: MySQLCatalogColumnDetail]
    ) -> MySQLCreateTableDefaults.Scope? {
        let identity = serverIdentity
        guard identity.flavor.isMariaDB else {
            let needsExpressions = showRows.contains { row in
                mysqlExpressionDefaultNeedsCreateTable(
                    row[safe: 5]?.asText, extra: row[safe: 6]?.asText, dataType: row[safe: 1]?.asText ?? ""
                )
            }
            return needsExpressions ? .expressionDefaults : nil
        }
        guard MySQLServerVersion.mariaDBDefaultsCanBeExpressions(banner: identity.banner, flavor: identity.flavor),
              !catalogDetails.values.contains(where: { $0.catalogDefault != nil })
        else { return nil }
        return .everyColumn
    }

    /// MySQL and MariaDB disagree on this catalog: MySQL 8 has no TABLE_NAME on CHECK_CONSTRAINTS
    /// and must join TABLE_CONSTRAINTS to find the owning table, while MariaDB carries TABLE_NAME
    /// directly. Neither exposes the columns a check touches, so `columns` stays empty rather than
    /// being guessed from the expression.
    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        let identity = serverIdentity
        let flavor = identity.flavor
        switch MySQLCheckConstraints.source(banner: identity.banner, flavor: flavor) {
        case .unavailable:
            return []
        case .databendCatalog:
            return try await databendCheckConstraints(table: table, schema: schema)
        case .createTableStatement:
            return try await createTableCheckConstraints(table: table, schema: schema)
        case .informationSchema:
            break
        }
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
        let result = try await execute(ownStatement: query)
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
        let database = effectiveSchema(schema)
        return try await catalogOrShow(
            database: database,
            catalog: { try await self.informationSchemaColumns(schema: schema, table: nil) },
            show: { try await self.showColumnsByTable(database: database) }
        )
    }

    private func informationSchemaColumns(
        schema: String?,
        table: String?
    ) async throws -> [String: [PluginColumnInfo]] {
        let escapedDb = effectiveSchemaLiteral(schema)
        let tableFilter = table.map { " AND TABLE_NAME = '\(mysqlEscapeStringLiteral($0))'" } ?? ""
        let identity = serverIdentity
        let hasGenerationExpression = MySQLServerVersion.hasGenerationExpression(
            banner: identity.banner, flavor: identity.flavor
        )
        let generationProjection = hasGenerationExpression ? "GENERATION_EXPRESSION" : "NULL"
        let query = """
            SELECT
                TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLLATION_NAME,
                IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT,
                \(generationProjection)
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = '\(escapedDb)'\(tableFilter)
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """

        let result = try await execute(ownStatement: query)
        let createTableClausesByTable = try await oceanbaseDefaultClausesByTable(
            forRows: result.rows, tableColumn: 0, typeColumn: 2, defaultColumn: 6, schema: schema
        )
        let createTableDefaultsByTable = try await createTableDefaultsByTable(
            forCatalogRows: result.rows, schema: schema
        )

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
            let defaultValue = columnDefaultValue(
                catalogDefault: rawDefault,
                extra: extra,
                dataType: normalizedType,
                isNullable: isNullable,
                column: name,
                createTableClauses: createTableClausesByTable[tableName],
                createTableDefaults: createTableDefaultsByTable[tableName]
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

/// What the catalog adds to one `SHOW FULL COLUMNS` row. `catalogDefault` is nil when the read did
/// not project a default, which is every server whose catalog does not quote its literals.
internal struct MySQLCatalogColumnDetail: Equatable, Sendable {
    let generationExpression: String?
    let catalogDefault: MySQLCatalogDefault?
}
