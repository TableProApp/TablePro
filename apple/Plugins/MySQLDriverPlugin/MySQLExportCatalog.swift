//
//  MySQLExportCatalog.swift
//  MySQLDriverPlugin
//

import Foundation
import os
import TableProMySQLCore
import TableProPluginKit

// The catalog reads and statements an export takes, over the caller's runner, so the Mac plugin and the iOS driver
// send the same SQL and map the same rows.
nonisolated struct MySQLExportCatalog: Sendable {
    typealias Run = @Sendable (String) async throws -> PluginQueryResult

    struct SessionHooks: Sendable {
        // Runs outside the footprint and the idle clock, spelled for the session like `run`.
        let runSetup: Run
        let transactionState: @Sendable () async -> PluginSessionTransactionState
        let adjustFootprint: @Sendable ((inout MySQLSessionFootprint) -> Void) -> Void
    }

    static let tableDDLIncludesForeignKeys = true
    static let defaultHost = "%"

    let banner: String?
    let flavor: MySQLServerFlavor
    let activeDatabase: String
    let quote: @Sendable (String) -> String
    // Takes a statement spelled with backslash escapes and runs it spelled for the session that reads it.
    let run: Run
    let schemaNamesAreCaseSensitive: @Sendable () async -> Bool
    // True for a server refusal that says the catalog cannot answer, false for a failed connection.
    let settlesBlindness: @Sendable (any Error) -> Bool

    private static let logger = Logger(subsystem: "com.TablePro", category: "MySQLExportCatalog")

    private static let excludedPrivileges: Set<String> = ["GRANT OPTION", "PROXY"]
    private static let tableContextMarkers = ["TABLE", "INDEX", "VIEW", "TRIGGER"]
    private static let databaseContextMarkers = [
        "DATABASE", "TABLE", "INDEX", "VIEW", "TRIGGER", "EVENT", "FUNCTION", "PROCEDURE"
    ]
    private static let columnGrantablePrivileges: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "REFERENCES"
    ]

    // MARK: - Server facts

    func holds(_ floor: (String?, MySQLServerFlavor) -> Bool) -> Bool {
        floor(banner, flavor)
    }

    var hasInformationSchema: Bool {
        holds(MySQLServerVersion.hasInformationSchema(banner:flavor:))
    }

    // The catalog read needs `REFERENTIAL_CONSTRAINTS` as well as `KEY_COLUMN_USAGE`; 5.0.96 has only the second.
    var hasForeignKeyCatalog: Bool {
        hasInformationSchema && holds(MySQLServerVersion.hasReferentialConstraintsCatalog(banner:flavor:))
    }

    var omittedForeignKeyAction: String {
        MySQLServerVersion.omittedForeignKeyAction(banner: banner, flavor: flavor)
    }

    func effectiveSchema(_ schema: String?) -> String {
        MySQLObjectQueries.effectiveSchema(schema, activeDatabase: activeDatabase)
    }

    // With no database selected an unqualified name is the only form the server takes.
    func qualifiedName(_ name: String, schema: String?) -> String {
        MySQLObjectQueries.qualifiedIdentifier(schema: effectiveSchema(schema).nilIfEmpty, name: name, quote: quote)
    }

    // True under `lower_case_table_names = 0`; nil when the server does not answer.
    static func schemaNameCaseSensitivity(run: Run) async -> Bool? {
        guard let result = try? await run(MySQLObjectQueries.lowerCaseTableNames),
              let setting = result.rows.first?[safe: 0]?.asText.flatMap({ Int($0) })
        else { return nil }
        return setting == 0
    }

    // MARK: - Table and view DDL

    // Nil when the server answered without the statement.
    func tableDDL(table: String, schema: String?) async throws -> String? {
        let result = try await run("SHOW CREATE TABLE \(qualifiedName(table, schema: schema))")
        guard let ddl = result.rows.first?[safe: 1]?.asText else { return nil }
        return ddl.hasSuffix(";") ? ddl : ddl + ";"
    }

    func viewDefinition(view: String, schema: String?) async throws -> String? {
        // StarRocks's `SHOW CREATE VIEW` rewrites a materialized view as a plain `CREATE VIEW`.
        let show = flavor.isStarRocks ? "SHOW CREATE TABLE" : "SHOW CREATE VIEW"
        let result = try await run("\(show) \(qualifiedName(view, schema: schema))")
        return result.rows.first?[safe: 1]?.asText
    }

    func approximateRowCount(table: String, schema: String?) async throws -> Int? {
        let result = try await run(MySQLObjectQueries.approximateRowCount(schema: effectiveSchema(schema), table: table))
        guard let value = result.rows.first?[safe: 0]?.asText, let count = Int(value) else { return nil }
        return count
    }

    // MARK: - Routines

    // The routines and their parameters are two reads; `MySQLRoutineSignatures` says why.
    func routines(schema: String?) async throws -> [PluginRoutineInfo] {
        guard flavor.hasMySQLObjectCatalogs, hasInformationSchema else { return [] }
        let resolvedSchema = effectiveSchema(schema)
        let exactSchema = await schemaNamesAreCaseSensitive()
        let result = try await run(MySQLObjectQueries.routineList(schema: resolvedSchema, exactSchema: exactSchema))
        let signatures = result.rows.isEmpty
            ? nil
            : try await routineSignatures(schema: resolvedSchema, exactSchema: exactSchema)
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let type = row[safe: 1]?.asText ?? ""
            let isProcedure = type.uppercased() == "PROCEDURE"
            let owner = row[safe: 7]?.asText ?? resolvedSchema
            var attributes: [PluginObjectAttribute] = []
            if let access = row[safe: 3]?.asText, !access.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Data Access", value: access))
            }
            if let deterministic = row[safe: 4]?.asText, !deterministic.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Deterministic", value: deterministic))
            }
            if let security = row[safe: 5]?.asText, !security.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Security", value: security))
            }
            if let definer = row[safe: 6]?.asText, !definer.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Definer", value: definer))
            }
            return PluginRoutineInfo(
                name: name,
                kind: isProcedure ? .procedure : .function,
                schema: owner,
                returnType: isProcedure ? nil : row[safe: 2]?.asText,
                language: "SQL",
                argumentSignature: signatures?.signature(schema: owner, type: type, routine: name),
                identity: nil,
                attributes: attributes
            )
        }
    }

    // Nil before 5.5.3, which has no `PARAMETERS` table, so a signature there is unknown rather than empty.
    private func routineSignatures(schema: String, exactSchema: Bool) async throws -> MySQLRoutineSignatures? {
        guard holds(MySQLServerVersion.hasParametersCatalog(banner:flavor:)) else { return nil }
        let result = try await run(MySQLObjectQueries.routineParameters(schema: schema, exactSchema: exactSchema))
        var signatures = MySQLRoutineSignatures()
        for row in result.rows {
            guard let owner = row[safe: 0]?.asText,
                  let type = row[safe: 1]?.asText,
                  let routine = row[safe: 2]?.asText
            else { continue }
            signatures.append(
                schema: owner,
                type: type,
                routine: routine,
                mode: row[safe: 3]?.asText,
                name: row[safe: 4]?.asText,
                dataType: row[safe: 5]?.asText
            )
        }
        return signatures
    }

    func routineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let kind = routine.kind == .procedure ? "PROCEDURE" : "FUNCTION"
        let query = MySQLObjectQueries.routineDefinition(
            kind: kind,
            schema: effectiveSchema(routine.schema),
            name: routine.name
        )
        let result = try await run(query)
        guard let row = result.rows.first else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        // A NULL body is the server hiding it from an account without SHOW_ROUTINE, not a missing routine.
        guard let ddl = row[safe: 2]?.asText, !ddl.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        return ddl
    }

    // Nil for a flavor without stored routines, which leaves the caller's own statement.
    func dropRoutineStatement(name: String, schema: String?, isFunction: Bool) -> String? {
        guard flavor.hasMySQLObjectCatalogs else { return nil }
        return MySQLObjectQueries.dropRoutine(
            isFunction: isFunction,
            schema: effectiveSchema(schema).nilIfEmpty,
            name: name,
            quote: quote
        )
    }

    // MARK: - Triggers

    func allTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        guard flavor.hasMySQLObjectCatalogs else { return [] }
        return try await triggerList(schema: effectiveSchema(schema), table: nil)
    }

    func triggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await triggerList(schema: effectiveSchema(trigger.schema), table: trigger.table)
        guard let match = listed.first(where: { $0.name == trigger.name }) else {
            throw PluginObjectSourceError.notFound(trigger.name)
        }
        guard let definition = match.definition, !definition.isEmpty else {
            throw PluginObjectSourceError.unsupported(trigger.name)
        }
        return definition
    }

    // The sidebar list, the per-table read and the DDL lookup all come through here. 5.0.10 added `TRIGGERS`.
    func triggerList(schema: String, table: String?) async throws -> [PluginTriggerInfo] {
        guard holds(MySQLServerVersion.hasTriggerCatalog(banner:flavor:)) else { return [] }
        let result = try await run(MySQLObjectQueries.triggerList(schema: schema, table: table))
        let flavor = self.flavor
        return result.rows.compactMap { row -> PluginTriggerInfo? in
            guard let name = row[safe: 0]?.asText,
                  let owningTable = row[safe: 1]?.asText,
                  let timing = row[safe: 3]?.asText,
                  let event = row[safe: 4]?.asText,
                  let body = row[safe: 6]?.asText
            else { return nil }
            let resolvedSchema = row[safe: 2]?.asText ?? schema
            let orientation = row[safe: 5]?.asText
            let condition = row[safe: 7]?.asText
            let definer = row[safe: 8]?.asText
            // A condition that is not one expression could end the statement it is assembled into.
            let assembles = condition.map { $0.isEmpty || mysqlIsSingleExpression($0, flavor: flavor) } ?? true
            let header = MySQLObjectQueries.triggerStatement(
                name: name,
                table: owningTable,
                schema: resolvedSchema,
                timing: timing,
                event: event,
                orientation: orientation,
                condition: condition,
                definer: definer
            )
            var attributes: [PluginObjectAttribute] = []
            if let definer, !definer.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Definer", value: definer))
            }
            if let order = row[safe: 9]?.asText, !order.isEmpty, order != "0" {
                attributes.append(PluginObjectAttribute(label: "Action Order", value: order))
            }
            return PluginTriggerInfo(
                name: name,
                table: owningTable,
                schema: resolvedSchema,
                timing: timing,
                event: event,
                orientation: orientation,
                statement: body,
                definition: assembles ? "\(header)\n\(body)" : nil,
                enabled: nil,
                attributes: attributes
            )
        }
    }

    func dropTriggerStatement(name: String, schema: String?) -> String {
        MySQLObjectQueries.dropTrigger(schema: effectiveSchema(schema).nilIfEmpty, name: name, quote: quote)
    }

    // MARK: - Events

    // `information_schema.EVENTS` lists them, and `SHOW CREATE EVENT` is the only runnable definition.
    func events(schema: String?) async throws -> [PluginEventInfo] {
        guard flavor.hasMySQLObjectCatalogs,
              holds(MySQLServerVersion.hasPartitionAndEventCatalogs(banner:flavor:))
        else { return [] }
        let exactSchema = await schemaNamesAreCaseSensitive()
        let result = try await run(MySQLObjectQueries.eventList(schema: effectiveSchema(schema), exactSchema: exactSchema))
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            return PluginEventInfo(
                name: name,
                schema: row[safe: 3]?.asText,
                kind: row[safe: 1]?.asText,
                isEnabled: row[safe: 2]?.asText?.uppercased() == "ENABLED"
            )
        }
    }

    func eventDDL(_ event: PluginEventInfo) async throws -> String {
        let result = try await run("SHOW CREATE EVENT \(qualifiedName(event.name, schema: event.schema))")
        guard let row = result.rows.first, let ddl = row[safe: 3]?.asText else {
            throw PluginObjectSourceError.unsupported(event.name)
        }
        return ddl
    }

    // MARK: - Creation scopes

    func routineCreationScope(_ routine: PluginRoutineInfo) async throws -> PluginStatementScope? {
        guard flavor.hasMySQLObjectCatalogs, hasInformationSchema else { return nil }
        let exactSchema = await schemaNamesAreCaseSensitive()
        let query = MySQLObjectQueries.routineCreationSettings(
            schema: effectiveSchema(routine.schema),
            name: routine.name,
            kind: routine.kind == .procedure ? "PROCEDURE" : "FUNCTION",
            exactSchema: exactSchema
        )
        let row = try await creationSettingsRow(query, named: routine.name)
        return Self.creationScope(sqlMode: row?[safe: 1]?.asText, timeZone: nil)
    }

    func triggerCreationScope(_ trigger: PluginTriggerInfo) async throws -> PluginStatementScope? {
        guard flavor.hasMySQLObjectCatalogs, holds(MySQLServerVersion.hasTriggerCatalog(banner:flavor:)) else {
            return nil
        }
        let query = MySQLObjectQueries.triggerCreationSettings(schema: effectiveSchema(trigger.schema), name: trigger.name)
        let row = try await creationSettingsRow(query, named: trigger.name)
        return Self.creationScope(sqlMode: row?[safe: 1]?.asText, timeZone: nil)
    }

    func eventCreationScope(_ event: PluginEventInfo) async throws -> PluginStatementScope? {
        guard flavor.hasMySQLObjectCatalogs, holds(MySQLServerVersion.hasPartitionAndEventCatalogs(banner:flavor:)) else {
            return nil
        }
        let exactSchema = await schemaNamesAreCaseSensitive()
        let query = MySQLObjectQueries.eventCreationSettings(
            schema: effectiveSchema(event.schema),
            name: event.name,
            exactSchema: exactSchema
        )
        let row = try await creationSettingsRow(query, named: event.name)
        return Self.creationScope(sqlMode: row?[safe: 1]?.asText, timeZone: row?[safe: 2]?.asText)
    }

    // Nil when the catalog has no row for the object, or no recorded mode.
    static func creationScope(sqlMode: String?, timeZone: String?) -> PluginStatementScope? {
        guard let sqlMode, let settings = MySQLCreationSettings(sqlMode: sqlMode, timeZone: timeZone) else { return nil }
        return PluginStatementScope(opening: settings.opening, closing: settings.closing)
    }

    private func creationSettingsRow(_ query: String, named name: String) async throws -> [PluginCellValue]? {
        let result = try await run(query)
        return result.rows.first { $0[safe: 0]?.asText == name }
    }

    // MARK: - Foreign keys

    // Two single-catalog reads merged here rather than one join: ShardingSphere-Proxy 5.5.3 answers any join of two
    // `information_schema` tables with an OK packet and no columns, and each read on its own correctly.
    func catalogForeignKeys(database: String, table: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let columns = try await run(MySQLObjectQueries.foreignKeyColumns(schema: database, table: table))
        let columnRows = columns.rows.compactMap { row -> MySQLForeignKeyCatalog.ColumnRow? in
            guard let tableName = row[safe: 0]?.asText,
                  let constraint = row[safe: 1]?.asText,
                  let column = row[safe: 2]?.asText,
                  let referencedTable = row[safe: 4]?.asText,
                  let referencedColumn = row[safe: 5]?.asText
            else { return nil }
            return MySQLForeignKeyCatalog.ColumnRow(
                table: tableName,
                constraint: constraint,
                column: column,
                referencedSchema: row[safe: 3]?.asText,
                referencedTable: referencedTable,
                referencedColumn: referencedColumn
            )
        }
        guard !columnRows.isEmpty else { return [:] }

        let actions = try await run(MySQLObjectQueries.referentialActions(schema: database, table: table))
        let actionRows = actions.rows.compactMap { row -> MySQLForeignKeyCatalog.ActionRow? in
            guard let tableName = row[safe: 0]?.asText,
                  let constraint = row[safe: 1]?.asText
            else { return nil }
            return MySQLForeignKeyCatalog.ActionRow(
                table: tableName,
                constraint: constraint,
                onDelete: row[safe: 2]?.asText ?? "",
                onUpdate: row[safe: 3]?.asText ?? ""
            )
        }

        return MySQLForeignKeyCatalog.group(
            columnRows: columnRows,
            actionRows: actionRows.filter { !$0.onDelete.isEmpty && !$0.onUpdate.isEmpty },
            defaultAction: omittedForeignKeyAction
        )
    }

    // MARK: - Columns

    // `GENERATION_EXPRESSION` is projected here so the bulk read agrees with the per-table one on generated columns.
    func informationSchemaColumns(schema: String?, table: String?) async throws -> [String: [PluginColumnInfo]] {
        let query = MySQLObjectQueries.columnCatalog(
            schema: effectiveSchema(schema),
            table: table,
            projectsGenerationExpression: holds(MySQLServerVersion.hasGenerationExpression(banner:flavor:))
        )
        let result = try await run(query)
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

    // Nil when the statement is refused, or does not describe a table: a view's leaves its columns on the catalog's
    // answer.
    func createTableDefaultClauses(table: String, schema: String?) async throws -> [String: String]? {
        do {
            let result = try await run("SHOW CREATE TABLE \(qualifiedName(table, schema: schema))")
            guard let createTable = result.rows.first?[safe: 1]?.asText else { return nil }
            return MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: createTable)
        } catch let error where settlesBlindness(error) {
            Self.logger.warning("create table default read refused: \(error.localizedDescription)")
            return nil
        }
    }

    // One `SHOW CREATE TABLE` per table holding a default its catalog row cannot recreate. On a MariaDB from 10.2.7
    // the catalog rows are already exact.
    private func createTableDefaultsByTable(
        forCatalogRows rows: [[PluginCellValue]],
        schema: String?
    ) async throws -> [String: MySQLCreateTableDefaults] {
        guard !flavor.isOceanBase else { return [:] }
        let scope: MySQLCreateTableDefaults.Scope
        let needsCreateTable: ([PluginCellValue]) -> Bool
        if flavor.isMariaDB {
            guard holds(MySQLServerVersion.mariaDBDefaultsCanBeExpressions(banner:flavor:)),
                  !holds(MySQLServerVersion.quotesColumnDefault(banner:flavor:))
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

    private func oceanbaseDefaultClausesByTable(
        forRows rows: [[PluginCellValue]],
        tableColumn: Int,
        typeColumn: Int,
        defaultColumn: Int,
        schema: String?
    ) async throws -> [String: [String: String]] {
        guard flavor.isOceanBase else { return [:] }
        let candidates = Set(rows.compactMap { row -> String? in
            guard let table = row[safe: tableColumn]?.asText,
                  let dataType = row[safe: typeColumn]?.asText,
                  OceanBaseColumnDefaults.catalogDefaultNeedsCreateTable(
                      row[safe: defaultColumn]?.asText, dataType: dataType
                  )
            else { return nil }
            return table
        })
        guard !candidates.isEmpty else { return [:] }
        var clausesByTable: [String: [String: String]] = [:]
        for table in try await baseTableNames(among: candidates, schema: schema).sorted() {
            clausesByTable[table] = try await oceanbaseDefaultClauses(table: table, schema: schema)
        }
        return clausesByTable
    }

    private func columnDefaultValue(
        catalogDefault: String?,
        extra: String?,
        dataType: String,
        isNullable: Bool,
        column: String,
        createTableClauses: [String: String]?,
        createTableDefaults: MySQLCreateTableDefaults?
    ) -> String? {
        guard flavor.isOceanBase else {
            let quotesDefaults = holds(MySQLServerVersion.quotesColumnDefault(banner:flavor:))
            return mysqlColumnDefault(
                createTableDefaults?.catalogDefault(forColumn: column, extra: extra)
                    ?? (quotesDefaults ? .quoted(catalogDefault) : .bare(catalogDefault)),
                extra: extra,
                dataType: dataType,
                isNullable: isNullable,
                banner: banner,
                flavor: flavor
            )
        }
        if let catalogDefault, let createTableClauses,
           OceanBaseColumnDefaults.catalogDefaultNeedsCreateTable(catalogDefault, dataType: dataType) {
            let resolution = OceanBaseColumnDefaults.resolve(
                clause: createTableClauses[column], catalogDefault: catalogDefault
            )
            if case .value(let value) = resolution {
                return value
            }
            Self.logger.warning(
                "OceanBase default of \(column, privacy: .private(mask: .hash)) is not in SHOW CREATE TABLE as reported"
            )
        }
        return OceanBaseColumnDefaults.columnDefault(
            catalogDefault, extra: extra, dataType: dataType, isNullable: isNullable
        )
    }

    private func baseTableNames(among tables: Set<String>, schema: String?) async throws -> Set<String> {
        let names = tables.sorted().map { "'\(mysqlEscapeStringLiteral($0))'" }.joined(separator: ", ")
        let result = try await run("""
            SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_SCHEMA = '\(mysqlEscapeStringLiteral(effectiveSchema(schema)))'
                AND TABLE_TYPE = 'BASE TABLE'
                AND TABLE_NAME IN (\(names))
            """)
        return Set(result.rows.compactMap { $0[safe: 0]?.asText })
    }

    private func oceanbaseDefaultClauses(table: String, schema: String?) async throws -> [String: String] {
        let result = try await run("SHOW CREATE TABLE \(qualifiedName(table, schema: schema))")
        guard let createTable = result.rows.first?[safe: 1]?.asText else { return [:] }
        return MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: createTable) ?? [:]
    }

    // MARK: - Session scope

    // Databend has no `sql_mode` or foreign key checks to hold, and a server before 5.0.3 cannot filter `SHOW` with
    // `WHERE`.
    func openSessionScope(for purpose: PluginSessionPurpose, hooks: SessionHooks) async throws -> PluginSessionScope? {
        let names = MySQLSessionScopePlan.savedNames(for: purpose)
        guard flavor.hasMySQLObjectCatalogs,
              holds(MySQLServerVersion.showAcceptsWhere(banner:flavor:)),
              !names.isEmpty
        else { return nil }
        let saved = try await Self.readSessionSettings(names, hooks: hooks)
        guard let applied = MySQLSessionScopePlan.applied(for: purpose, saved: saved) else { return nil }
        guard !applied.isEmpty else {
            return PluginSessionScope(purpose: purpose, saved: saved, applied: [])
        }
        let statements = applied.compactMap { MySQLSessionStatements.assignment(name: $0.name, value: $0.value) }
        let savedNames = Set(saved.map(\.name))
        // A setting with no saved value could not be put back, so the scope sets none of them.
        guard statements.count == applied.count, applied.allSatisfy({ savedNames.contains($0.name) }) else {
            Self.logger.warning("The server did not report every setting a session scope sets; running without one")
            return nil
        }
        // Held before the first `SET`, so the idle release cannot hand the session back between two of them.
        hooks.adjustFootprint({ $0.holdSessionScope() })
        do {
            for statement in statements {
                _ = try await hooks.runSetup(statement)
            }
        } catch {
            let isRestored = await Self.restoreAfterFailedOpen(saved, hooks: hooks)
            hooks.adjustFootprint({ $0.releaseSessionScope(isRestored: isRestored) })
            throw error
        }
        return PluginSessionScope(purpose: purpose, saved: saved, applied: applied)
    }

    func closeSessionScope(_ scope: PluginSessionScope, hooks: SessionHooks) async throws {
        guard flavor.hasMySQLObjectCatalogs else { return }
        let heldSession = !scope.applied.isEmpty
        let isRestored: Bool
        do {
            isRestored = try await Self.restoreSessionSettings(scope.saved, hooks: hooks)
        } catch {
            Self.noteClosedScope(heldSession: heldSession, isRestored: false, hooks: hooks)
            throw error
        }
        Self.noteClosedScope(heldSession: heldSession, isRestored: isRestored, hooks: hooks)
    }

    private static func noteClosedScope(heldSession: Bool, isRestored: Bool, hooks: SessionHooks) {
        hooks.adjustFootprint({ footprint in
            if heldSession {
                footprint.releaseSessionScope(isRestored: isRestored)
            } else if !isRestored {
                footprint.noteUnrestoredSessionSettings()
            }
        })
    }

    private static func readSessionSettings(_ names: [String], hooks: SessionHooks) async throws -> [PluginSessionSetting] {
        guard let query = MySQLSessionStatements.captureQuery(names: names) else { return [] }
        let result = try await hooks.runSetup(query)
        return MySQLSessionScopePlan.captured(rows: result.rows, names: names)
    }

    // Every statement is tried, so one refused value does not leave the others changed, and the first refusal is
    // what the caller hears. False when a setting had to stay changed. Any state but `.idle`, `.unknown` included,
    // keeps `autocommit` from committing a transaction that may be the user's.
    private static func restoreSessionSettings(_ saved: [PluginSessionSetting], hooks: SessionHooks) async throws -> Bool {
        guard !saved.isEmpty else { return true }
        let current = try await readSessionSettings(saved.map(\.name), hooks: hooks)
        let isTransactionOpen = await hooks.transactionState() != .idle
        let restore = MySQLSessionScopePlan.restore(saved: saved, current: current, isTransactionOpen: isTransactionOpen)
        if !restore.isComplete {
            logger.info("Left autocommit as the imported file set it, because the session holds an open transaction")
        }
        var firstFailure: Error?
        for statement in restore.statements {
            do {
                _ = try await hooks.runSetup(statement)
            } catch {
                logger.error(
                    "Could not put a session setting back with \(statement, privacy: .private): \(error.localizedDescription)"
                )
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure {
            throw firstFailure
        }
        return restore.isComplete
    }

    private static func restoreAfterFailedOpen(_ saved: [PluginSessionSetting], hooks: SessionHooks) async -> Bool {
        do {
            return try await restoreSessionSettings(saved, hooks: hooks)
        } catch {
            logger.error("A session scope that failed to open could not put its settings back")
            return false
        }
    }

    // MARK: - Principals and grants

    func principals() async throws -> [PluginPrincipalInfo] {
        let readsLimit = !flavor.isTiDB && holds(MySQLServerVersion.hasUserConnectionLimit(banner:flavor:))
        let query = readsLimit
            ? "SELECT User, Host, max_user_connections FROM mysql.user ORDER BY User, Host"
            : "SELECT User, Host FROM mysql.user ORDER BY User, Host"
        let result = try await run(query)

        return result.rows.compactMap { row -> PluginPrincipalInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let host = row[safe: 1]?.asText ?? Self.defaultHost
            let limit = row[safe: 2]?.asText.flatMap(Int.init)

            return PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: name, host: host),
                isRole: false,
                canLogin: true,
                connectionLimit: (limit ?? 0) == 0 ? nil : limit
            )
        }
    }

    func privilegeCatalog() async throws -> PluginPrivilegeCatalog {
        let result = try await run("SHOW PRIVILEGES")

        var server: [PluginPrivilegeDescriptor] = []
        var database: [PluginPrivilegeDescriptor] = []
        var table: [PluginPrivilegeDescriptor] = []
        var column: [PluginPrivilegeDescriptor] = []
        var hasDynamicPrivileges = false

        for row in result.rows {
            guard let rawName = row[safe: 0]?.asText,
                  let name = PluginPrivilegeName.sanitized(rawName),
                  !Self.excludedPrivileges.contains(name) else { continue }

            let isDynamic = MySQLPrivilegeCatalog.isDynamic(name)
            hasDynamicPrivileges = hasDynamicPrivileges || isDynamic

            let descriptor = PluginPrivilegeDescriptor(
                name: name,
                label: rawName,
                category: MySQLPrivilegeCatalog.category(for: name)
            )
            server.append(descriptor)

            guard !isDynamic else { continue }
            let context = (row[safe: 1]?.asText ?? "").uppercased()

            if Self.databaseContextMarkers.contains(where: { context.contains($0) }) {
                database.append(descriptor)
            }
            if Self.tableContextMarkers.contains(where: { context.contains($0) }) {
                table.append(descriptor)
            }
            if Self.columnGrantablePrivileges.contains(name) {
                column.append(descriptor)
            }
        }

        return PluginPrivilegeCatalog(
            serverPrivileges: server,
            databasePrivileges: database,
            schemaPrivileges: [],
            tablePrivileges: table,
            columnPrivileges: column,
            supportsDynamicPrivileges: hasDynamicPrivileges
        )
    }

    func grants(for principal: PluginPrincipalRef, privileges: PluginPrivilegeCatalog) async throws -> [PluginGrantInfo] {
        let result = try await run("SHOW GRANTS FOR \(Self.grantAccount(principal, quote: quote))")
        return result.rows.flatMap { row -> [PluginGrantInfo] in
            guard let line = row[safe: 0]?.asText,
                  let parsed = MySQLGrantParser.parseGrant(line) else { return [] }
            return Self.grants(from: parsed, catalog: privileges)
        }
    }

    func grantStatements(for principal: PluginPrincipalRef, grants: [PluginGrantInfo]) -> [String] {
        Self.grantBuilder(for: principal, quote: quote).grantStatements(grants)
    }

    static func grantBuilder(
        for principal: PluginPrincipalRef,
        quote: @escaping @Sendable (String) -> String
    ) -> PluginGrantSQLBuilder {
        PluginGrantSQLBuilder(
            grantee: grantAccount(principal, quote: quote),
            quoteIdentifier: quote,
            target: { grantTarget(for: $0, quote: quote) }
        )
    }

    static func grantAccount(_ principal: PluginPrincipalRef, quote: (String) -> String) -> String {
        let name = quote(principal.name)
        let host = quote(principal.host ?? defaultHost)
        return "\(name)@\(host)"
    }

    // MySQL treats `_` and `%` in the database position as LIKE wildcards only for global and database-level grants.
    // In a table-level target the database name is a literal identifier, so escaping it there would grant on a
    // database whose name contains a backslash.
    static func grantTarget(for scope: PluginPrivilegeScope, quote: (String) -> String) -> String? {
        switch scope {
        case .server:
            "*.*"
        case let .database(name):
            "\(quotedDatabasePattern(name, quote: quote)).*"
        case let .schema(database, _):
            "\(quotedDatabasePattern(database, quote: quote)).*"
        case let .table(database, _, table):
            "\(quote(database)).\(quote(table))"
        case let .column(database, _, table, _):
            "\(quote(database)).\(quote(table))"
        @unknown default:
            nil
        }
    }

    static func quotedDatabasePattern(_ name: String, quote: (String) -> String) -> String {
        quote(MySQLGrantPatternEscaping.escapeDatabasePattern(name))
    }

    private static func grants(
        from parsed: MySQLParsedGrant,
        catalog: PluginPrivilegeCatalog
    ) -> [PluginGrantInfo] {
        parsed.privileges.flatMap { privilege -> [PluginGrantInfo] in
            guard privilege.columns.isEmpty else {
                return columnGrants(privilege, in: parsed)
            }
            let names = privilege.name == MySQLGrantParser.allPrivileges
                ? catalog.privileges(for: parsed.scope).map(\.name)
                : [privilege.name]

            return names.map {
                PluginGrantInfo(privilege: $0, scope: parsed.scope, isGrantable: parsed.isGrantable)
            }
        }
    }

    private static func columnGrants(
        _ privilege: MySQLParsedPrivilege,
        in parsed: MySQLParsedGrant
    ) -> [PluginGrantInfo] {
        guard let database = parsed.scope.databaseName,
              let table = parsed.scope.tableName else { return [] }

        return privilege.columns.map { column in
            PluginGrantInfo(
                privilege: privilege.name,
                scope: .column(database: database, schema: nil, table: table, column: column),
                isGrantable: parsed.isGrantable
            )
        }
    }
}
