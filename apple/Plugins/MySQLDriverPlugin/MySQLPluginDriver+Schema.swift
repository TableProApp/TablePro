//
//  MySQLPluginDriver+Schema.swift
//  MySQLDriverPlugin
//
//  The column reads, and the rule they share for naming the database they mean.
//

import Foundation
import os
import TableProMySQLCore
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

    /// One table's `SHOW TABLE STATUS` row. Before 5.0.3 the statement takes a `LIKE` pattern only,
    /// which the server matches by its own collation, so the row is picked by name from the answer.
    func tableStatusRow(table: String, schema: String?) async throws -> [PluginCellValue]? {
        let query = MySQLObjectQueries.tableStatus(
            schema: effectiveSchema(schema),
            table: table,
            acceptsWhere: holdsForServer(MySQLServerVersion.showAcceptsWhere(banner:flavor:))
        )
        let result = try await execute(ownStatement: query)
        return MySQLTableStatusRow.row(named: table, in: result.rows)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard !flavor.isDatabend else {
            return try await databendColumns(table: table, schema: schema)
        }
        guard !flavor.isOceanBase else {
            let columnsByTable = try await exportCatalog.informationSchemaColumns(schema: schema, table: table)
            return columnsByTable[table] ?? (columnsByTable.count == 1 ? columnsByTable.values.first ?? [] : [])
        }
        guard !flavor.isStarRocks else {
            return try await starrocksColumns(database: effectiveSchema(schema), table: table)[table] ?? []
        }
        let reads: MySQLColumnReads
        if let flight = try await columnReadsInOneFlight(table: table, schema: schema) {
            reads = flight
        } else {
            reads = try await columnReadsOneByOne(table: table, schema: schema)
        }
        let catalogDetails = reads.catalogDetails
        let createTableDefaults = try await createTableDefaults(
            table: table, schema: schema, showRows: reads.showRows, catalogDetails: catalogDetails
        )
        let identity = serverIdentity

        let columns = reads.showRows.compactMap { row -> PluginColumnInfo? in
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
                isNullable: isNullable,
                banner: identity.banner,
                flavor: identity.flavor
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
        let checks = try await mariadbColumnChecks(
            table: table, schema: schema, columns: columns.map(\.name), knownClauses: reads.checkClauses
        )
        guard !checks.isEmpty else { return columns }
        return columns.map { $0.withColumnCheck(checks[$0.name]) }
    }

    private func columnReadsOneByOne(table: String, schema: String?) async throws -> MySQLColumnReads {
        let result = try await execute(query: "SHOW FULL COLUMNS FROM \(qualifiedName(table, schema: schema))")
        let details = try await fetchCatalogColumnDetails(table: table, schema: schema)
        return MySQLColumnReads(showRows: result.rows, catalogDetails: details, checkClauses: nil)
    }

    // Nil sends the caller to the one-by-one reads, which also cover every session this flight does not.
    private func columnReadsInOneFlight(table: String, schema: String?) async throws -> MySQLColumnReads? {
        let identity = serverIdentity
        let database = effectiveSchema(schema)
        guard MySQLServerVersion.readsInOneFlight(banner: identity.banner, flavor: identity.flavor),
              temporaryTableCandidates.isEmpty,
              catalogVisibility.visibility(of: database) != .blind,
              let catalogRead = columnCatalogRead(table: table, schema: schema)
        else { return nil }

        let readsChecks = identity.flavor.isMariaDB
            && MySQLCheckConstraints.source(banner: identity.banner, flavor: identity.flavor) == .informationSchema
        let level = MySQLCatalogColumn.checkConstraintLevel
        let plan = MySQLColumnFlight(
            readsChecks: readsChecks,
            levelIsPresent: readsChecks ? cachedCatalogColumnPresence(level.rawValue) : nil
        )
        let statements = plan.reads.map { read -> String in
            switch read {
            case .columns: "SHOW FULL COLUMNS FROM \(qualifiedName(table, schema: schema))"
            case .catalogDetails: catalogRead.query
            case .levelPresence: level.presenceQuery
            case .checkClauses: MySQLColumnChecks.clausesQuery(schema: database, table: table)
            }
        }
        guard let answers = try await readInOneFlight(statements) else { return nil }

        let outcome = try plan.outcome(of: answers, settlesBlindness: MySQLCatalogVisibilityRule.settlesBlindness(code:))
        for refusal in outcome.refusals {
            Self.logger.warning("column read refused code=\(refusal.code, privacy: .public) message=\(refusal.message)")
        }
        if let present = outcome.levelIsPresent {
            cacheCatalogColumnPresence(level.rawValue, present)
        }
        return MySQLColumnReads(
            showRows: outcome.showRows,
            catalogDetails: catalogRead.details(fromRows: outcome.catalogRows),
            checkClauses: outcome.checkClauses
        )
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
        guard serverHasInformationSchema,
              catalogVisibility.visibility(of: effectiveSchema(schema)) != .blind,
              await !resolvesToTemporaryTable(table, schema: schema),
              let catalogRead = columnCatalogRead(table: table, schema: schema)
        else { return [:] }
        do {
            return catalogRead.details(fromRows: try await execute(ownStatement: catalogRead.query).rows)
        } catch let error as MariaDBPluginError
            where MySQLCatalogVisibilityRule.settlesBlindness(code: error.code) {
            Self.logger.warning(
                "column catalog read refused code=\(error.code, privacy: .public) message=\(error.message)"
            )
            return [:]
        }
    }

    private func columnCatalogRead(table: String, schema: String?) -> MySQLColumnCatalogRead? {
        let identity = serverIdentity
        let readsGeneration = MySQLServerVersion.hasGenerationExpression(
            banner: identity.banner, flavor: identity.flavor
        )
        let readsDefault = MySQLServerVersion.quotesColumnDefault(banner: identity.banner, flavor: identity.flavor)
        guard readsGeneration || readsDefault else { return nil }
        let generationProjection = readsGeneration ? "GENERATION_EXPRESSION" : "NULL"
        let defaultProjection = readsDefault ? "COLUMN_DEFAULT" : "NULL"
        let generatedOnly = readsDefault ? "" : " AND GENERATION_EXPRESSION <> \'\'"
        let query = """
            SELECT COLUMN_NAME, \(generationProjection), \(defaultProjection)
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = \'\(effectiveSchemaLiteral(schema))\'
                AND TABLE_NAME = \'\(mysqlEscapeStringLiteral(table))\'\(generatedOnly)
            """
        return MySQLColumnCatalogRead(query: query, readsDefault: readsDefault)
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
              let clauses = try await exportCatalog.createTableDefaultClauses(table: table, schema: schema)
        else { return nil }
        return MySQLCreateTableDefaults(clauses: clauses, scope: scope)
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
            guard await !resolvesToTemporaryTable(table, schema: schema) else {
                return try await createTableCheckConstraints(table: table, schema: schema)
            }
        }
        let database = effectiveSchemaLiteral(schema)
        let safeTable = mysqlEscapeStringLiteral(table)
        let query: String
        if flavor.isMariaDB {
            // A column's own check is the column's, restated by its MODIFY: as a constraint here, its
            // DROP CONSTRAINT fails with ERROR 1091.
            let tableLevel = try await catalogHasColumn(.checkConstraintLevel) ? " AND LEVEL <> \'Column\'" : ""
            query = """
                SELECT CONSTRAINT_NAME, CHECK_CLAUSE
                FROM INFORMATION_SCHEMA.CHECK_CONSTRAINTS
                WHERE CONSTRAINT_SCHEMA = \'\(database)\' AND TABLE_NAME = \'\(safeTable)\'\(tableLevel)
                ORDER BY CONSTRAINT_NAME
                """
        } else {
            query = MySQLCheckConstraints.joinedCatalogQuery(databaseLiteral: database, tableLiteral: safeTable)
        }
        let result = try await execute(ownStatement: query)
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let clause = row[safe: 1]?.asText else { return nil }
            return PluginCheckConstraintInfo(name: name, expression: clause)
        }
    }

    // StarRocks answers the bulk read by loading every table's schema from the lake behind an external catalog.
    var providesBulkColumnFetch: Bool { !flavor.isStarRocks }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try await allColumns(schema: schema, keepsSpellingsApart: true)
    }

    func fetchAllColumnsForExport(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try await allColumns(schema: schema, keepsSpellingsApart: true)
    }

    private func allColumns(schema: String?, keepsSpellingsApart: Bool) async throws -> [String: [PluginColumnInfo]] {
        guard !flavor.isDatabend else {
            return try await databendAllColumns(schema: schema, keepsSpellingsApart: keepsSpellingsApart)
        }
        let database = effectiveSchema(schema)
        guard !flavor.isStarRocks else {
            return try await starrocksColumns(database: database, table: nil, keepsSpellingsApart: keepsSpellingsApart)
        }
        return try await catalogOrShow(
            database: database,
            catalogExists: serverHasInformationSchema,
            catalog: {
                try await self.exportCatalog.informationSchemaColumns(
                    schema: schema, table: nil, keepsSpellingsApart: keepsSpellingsApart
                )
            },
            show: { try await self.showColumnsByTable(database: database, keepsSpellingsApart: keepsSpellingsApart) }
        )
    }
}

/// What the catalog adds to one `SHOW FULL COLUMNS` row. `catalogDefault` is nil when the read did
/// not project a default, which is every server whose catalog does not quote its literals.
internal struct MySQLCatalogColumnDetail: Equatable, Sendable {
    let generationExpression: String?
    let catalogDefault: MySQLCatalogDefault?
}

internal struct MySQLColumnCatalogRead: Equatable, Sendable {
    let query: String
    let readsDefault: Bool

    func details(fromRows rows: [[PluginCellValue]]) -> [String: MySQLCatalogColumnDetail] {
        var details: [String: MySQLCatalogColumnDetail] = [:]
        for row in rows {
            guard let name = row[safe: 0]?.asText else { continue }
            details[name] = MySQLCatalogColumnDetail(
                generationExpression: row[safe: 1]?.asText?.nilIfEmpty,
                catalogDefault: readsDefault ? .quoted(row[safe: 2]?.asText) : nil
            )
        }
        return details
    }
}

// `checkClauses` is nil when the clauses have not been read yet.
internal struct MySQLColumnReads {
    let showRows: [[PluginCellValue]]
    let catalogDetails: [String: MySQLCatalogColumnDetail]
    let checkClauses: [String]?
}

// `SHOW CREATE TABLE` stays out of the flight: whether it runs depends on these answers.
internal struct MySQLColumnFlight: Equatable, Sendable {
    enum Read: Equatable, Sendable {
        case columns
        case catalogDetails
        case levelPresence
        case checkClauses
    }

    struct Refusal: Equatable, Sendable {
        let code: UInt32
        let message: String
    }

    struct FailureResponse: Equatable, Sendable {
        let stopsFlights: Bool
        let reportsFailure: Bool

        // The server may still be running what outlasted the socket timeout, so that read never goes out again.
        init(to error: MariaDBPluginError) {
            stopsFlights = mysqlClientErrorCodes.contains(error.code)
            reportsFailure = error.outlastedSocketTimeout
        }
    }

    struct Outcome {
        let showRows: [[PluginCellValue]]
        let catalogRows: [[PluginCellValue]]
        let levelIsPresent: Bool?
        let checkClauses: [String]
        let refusals: [Refusal]
    }

    let reads: [Read]

    // A lost connection clears the transaction flag, so a fallback could reconnect over a session that held state.
    static func mayRun(on footprint: MySQLSessionFootprint, isRefused: Bool) -> Bool {
        footprint.isClean && !isRefused
    }

    init(readsChecks: Bool, levelIsPresent: Bool?) {
        var reads: [Read] = [.columns, .catalogDetails]
        if readsChecks, levelIsPresent != false {
            if levelIsPresent == nil { reads.append(.levelPresence) }
            reads.append(.checkClauses)
        }
        self.reads = reads
    }

    // Decides as the one-by-one reads do: a refused catalog read degrades, anything else fails the whole read.
    func outcome(
        of answers: [Result<PluginQueryResult, MariaDBPluginError>],
        settlesBlindness: (UInt32) -> Bool
    ) throws -> Outcome {
        var showRows: [[PluginCellValue]] = []
        var catalogRows: [[PluginCellValue]] = []
        var levelIsPresent: Bool?
        var levelWasRefused = false
        var clauses: [String] = []
        var refusals: [Refusal] = []

        for (read, answer) in zip(reads, answers) {
            switch answer {
            case .success(let result):
                switch read {
                case .columns: showRows = result.rows
                case .catalogDetails: catalogRows = result.rows
                case .levelPresence:
                    levelIsPresent = (result.rows.first?[safe: 0]?.asText.flatMap { Int($0) } ?? 0) > 0
                case .checkClauses: clauses = result.rows.compactMap { $0[safe: 0]?.asText }
                }
            case .failure(let failure):
                // Sent before the answer on `LEVEL` was known, so a server without the column refuses it.
                if read == .checkClauses, levelIsPresent == false || levelWasRefused { continue }
                guard read != .columns, settlesBlindness(failure.code) else { throw failure }
                refusals.append(Refusal(code: failure.code, message: failure.message))
                if read == .levelPresence { levelWasRefused = true }
            }
        }
        let hasNoLevel = levelIsPresent == false || levelWasRefused
        return Outcome(
            showRows: showRows,
            catalogRows: catalogRows,
            levelIsPresent: levelIsPresent,
            checkClauses: hasNoLevel ? [] : clauses,
            refusals: refusals
        )
    }
}
