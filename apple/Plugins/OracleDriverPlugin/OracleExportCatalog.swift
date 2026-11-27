//
//  OracleExportCatalog.swift
//  OracleDriverPlugin
//

import Foundation
import os
import TableProOracleCore
import TableProPluginKit

nonisolated struct OraclePrincipalState: Sendable {
    var access: OracleDictionaryAccess?
    var roles: Set<String> = []
    var catalog: PluginPrivilegeCatalog?
}

// The catalog reads both apps run against Oracle, over the connection each app holds.
nonisolated struct OracleExportCatalog: Sendable {
    typealias Run = @Sendable (String) async throws -> OracleRawResult

    static let tableDDLIncludesForeignKeys = false

    let run: Run
    let currentSchema: String?
    let fallbackSchema: String
    let release: OracleServerRelease
    let principalState: OSAllocatedUnfairLock<OraclePrincipalState>
    // The server error inside what `run` threw, so a dictionary view the account cannot read is told apart.
    let coreError: @Sendable (Error) -> OracleCoreError?

    init(
        run: @escaping Run,
        currentSchema: String?,
        fallbackSchema: String,
        release: OracleServerRelease,
        principalState: OSAllocatedUnfairLock<OraclePrincipalState>,
        coreError: @escaping @Sendable (Error) -> OracleCoreError?
    ) {
        self.run = run
        self.currentSchema = currentSchema
        self.fallbackSchema = fallbackSchema
        self.release = release
        self.principalState = principalState
        self.coreError = coreError
    }

    func effectiveSchema(_ schema: String?) -> String {
        schema ?? currentSchema ?? fallbackSchema
    }

    // MARK: - Columns and keys

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let result = try await run(
            OracleSchemaQueries.columns(schema: effectiveSchema(schema), table: table, release: release)
        )
        return result.rows.compactMap(OracleSchemaQueries.parseColumnRow).map(\.pluginColumnInfo)
    }

    func fetchAllColumns(schema: String?, keepsSpellingsApart: Bool = false) async throws -> [String: [PluginColumnInfo]] {
        let result = try await run(OracleSchemaQueries.allColumns(schema: effectiveSchema(schema), release: release))
        let parsedRows = result.rows.compactMap(OracleSchemaQueries.parseTableColumnRow)
        if keepsSpellingsApart {
            try PluginNameSpellings.requireDistinctSpellings(parsedRows.map { $0.table })
        }
        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for (table, column) in parsedRows {
            columnsByTable[table, default: []].append(column.pluginColumnInfo)
        }
        return columnsByTable
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let result = try await run(OracleSchemaQueries.foreignKeys(schema: effectiveSchema(schema), table: table))
        return result.rows.compactMap(OracleSchemaQueries.parseForeignKeyRow).map {
            PluginForeignKeyInfo(
                name: $0.constraintName,
                column: $0.columnName,
                referencedTable: $0.referencedTable,
                referencedColumn: $0.referencedColumn,
                referencedSchema: $0.referencedSchema,
                onDelete: $0.deleteRule,
                onUpdate: "NO ACTION"
            )
        }
    }

    func fetchAllForeignKeys(
        schema: String?,
        keepsSpellingsApart: Bool = false
    ) async throws -> [String: [PluginForeignKeyInfo]] {
        let rows = try await cells(OracleSchemaQueries.allForeignKeys(schema: effectiveSchema(schema)))
        if keepsSpellingsApart {
            try PluginNameSpellings.requireDistinctSpellings(in: rows, nameAt: 0)
        }
        var fksByTable: [String: [PluginForeignKeyInfo]] = [:]
        for row in rows {
            guard let tableName = row[safe: 0]?.asText,
                  let constraintName = row[safe: 1]?.asText,
                  let columnName = row[safe: 2]?.asText,
                  let refTable = row[safe: 3]?.asText,
                  let refColumn = row[safe: 4]?.asText else { continue }
            let deleteRule = (row[safe: 5]?.asText) ?? "NO ACTION"
            let fk = PluginForeignKeyInfo(
                name: constraintName,
                column: columnName,
                referencedTable: refTable,
                referencedColumn: refColumn,
                referencedSchema: row[safe: 6]?.asText,
                onDelete: deleteRule,
                onUpdate: "NO ACTION"
            )
            fksByTable[tableName, default: []].append(fk)
        }
        return fksByTable
    }

    // MARK: - Definitions

    // `ALL_TAB_COLS` lists a view's columns as it lists a table's, so a view is looked up first.
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let owner = effectiveSchema(schema)
        let view = try await cells(OracleSchemaQueries.viewDefinition(schema: owner, view: table))
        if !view.isEmpty {
            return try await viewStatement(from: view, schema: owner, view: table)
        }
        let columns = try await fetchColumns(table: table, schema: schema)
        let constraints = try await run(
            OracleSchemaQueries.tableConstraints(schema: owner, table: table)
        )
        return try OracleTableDDL.createTable(
            qualifiedTable: Self.qualified(owner, table),
            columns: columns,
            constraints: OracleSchemaQueries.parseTableConstraints(constraints.rows),
            quote: OracleObjectQueries.quoteIdentifier
        )
    }

    // DBMS_METADATA.GET_DDL on the wrong object type raises ORA-31603, which breaks the connection's state machine.
    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let owner = effectiveSchema(schema)
        let rows = try await cells(OracleSchemaQueries.viewDefinition(schema: owner, view: view))
        return try await viewStatement(from: rows, schema: owner, view: view)
    }

    // TEXT is the view's SELECT alone; written bare, a restore ran the query and created no view.
    private func viewStatement(from rows: [[PluginCellValue]], schema: String, view: String) async throws -> String {
        guard let row = rows.first, let body = row.first?.asText,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OracleStatementError(
                message: String(format: String(localized: "Oracle returned no definition for view '%@'."), view)
            )
        }
        return OracleTableDDL.createView(
            qualifiedView: Self.qualified(schema, view),
            columns: try await fetchColumns(table: view, schema: schema).map(\.name),
            query: body,
            quote: OracleObjectQueries.quoteIdentifier
        )
    }

    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        let owner = effectiveSchema(schema)
        let result = try await run(OracleIndexStatements.query(schema: owner, table: table))
        let indexes = OracleIndexStatements.render(
            rows: result.rows.map { row in row.map { $0.stringValue } },
            schema: owner,
            table: table,
            quote: OracleObjectQueries.quoteIdentifier)
        let constraints = try await run(
            OracleSchemaQueries.tableConstraints(schema: owner, table: table)
        )
        return indexes + (try OracleTableDDL.afterRowsStatements(
            qualifiedTable: Self.qualified(owner, table),
            constraints: OracleSchemaQueries.parseTableConstraints(constraints.rows),
            quote: OracleObjectQueries.quoteIdentifier
        ))
    }

    // MARK: - Routines

    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let resolvedSchema = routineSchema(schema)
        let rows = try await cells(OracleObjectQueries.routineList(schema: resolvedSchema))
        return rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let objectType = (row[safe: 2]?.asText ?? "").uppercased()
            var attributes: [PluginObjectAttribute] = []
            if let status = row[safe: 3]?.asText, !status.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Status", value: status))
            }
            return PluginRoutineInfo(
                name: name,
                kind: objectType == "PROCEDURE" ? .procedure : .function,
                schema: row[safe: 1]?.asText ?? resolvedSchema,
                returnType: nil,
                language: "PL/SQL",
                argumentSignature: nil,
                identity: objectType,
                attributes: attributes
            )
        }
    }

    // ALL_SOURCE returns no rows at all when the caller cannot see the object, a privilege answer.
    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let query = OracleObjectQueries.routineSource(
            schema: routineSchema(routine.schema),
            name: routine.name,
            type: routine.kind == .procedure ? "PROCEDURE" : "FUNCTION"
        )
        let rows = try await cells(query)
        guard !rows.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        let body = rows
            .compactMap { $0[safe: 0]?.asText }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        return body.uppercased().hasPrefix("CREATE") ? body : "CREATE OR REPLACE \(body)"
    }

    static func dropRoutineStatement(name: String, schema: String?, currentSchema: String?, isFunction: Bool) -> String {
        OracleRoutineStatements.drop(name: name, schema: schema, currentSchema: currentSchema, isFunction: isFunction)
    }

    // MARK: - Triggers

    // A schema-wide read scopes on OWNER, the trigger's own schema.
    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await triggerList(schema: routineSchema(schema), table: nil)
    }

    // A per-table read scopes on TABLE_OWNER, the subject table's schema.
    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await triggerList(schema: effectiveSchema(schema), table: table)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await triggerList(schema: routineSchema(trigger.schema), table: trigger.table)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.insufficientPrivilege(trigger.name)
        }
        return definition
    }

    static func dropTriggerStatement(
        name: String,
        schema: String?,
        currentSchema: String?,
        release: OracleServerRelease?
    ) -> String {
        OracleDropStatements.drop(.trigger, name: name, schema: schema, currentSchema: currentSchema, release: release)
    }

    // The export's own `DROP TABLE IF EXISTS` parses only on 23ai and later.
    static func dropRelationStatement(
        kind: PluginExportObjectKind,
        name: String,
        schema: String?,
        currentSchema: String?,
        release: OracleServerRelease?
    ) -> String? {
        let relation: OracleDropStatements.Object
        switch kind {
        case .table: relation = .table
        case .view: relation = .view
        case .materializedView: relation = .materializedView
        default: return nil
        }
        return OracleDropStatements.drop(relation, name: name, schema: schema, currentSchema: currentSchema, release: release)
    }

    // Every drop a dump writes for Oracle. Nil for a routine whose `tableType` is not its `PluginRoutineKind`.
    func dropStatement(for object: PluginExportTable, schema: String?) -> String? {
        switch object.kind {
        case .trigger:
            return Self.dropTriggerStatement(
                name: object.name, schema: schema, currentSchema: currentSchema, release: release
            )
        case .routine:
            guard let kind = PluginRoutineKind(rawValue: object.tableType.lowercased()) else { return nil }
            return Self.dropRoutineStatement(
                name: object.name, schema: schema, currentSchema: currentSchema, isFunction: kind == .function
            )
        default:
            return Self.dropRelationStatement(
                kind: object.kind, name: object.name, schema: schema, currentSchema: currentSchema, release: release
            )
        }
    }

    private func triggerList(schema: String, table: String?) async throws -> [PluginTriggerInfo] {
        let rows = try await cells(OracleObjectQueries.triggerList(schema: schema, table: table))
        return rows.compactMap { row -> PluginTriggerInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let triggerType = row[safe: 3]?.asText ?? ""
            let owner = row[safe: 2]?.asText
            let body = row[safe: 10]?.asText
            let definition = OracleObjectQueries.triggerDefinition(OracleTriggerSource(
                name: name,
                owner: owner,
                tableOwner: row[safe: 9]?.asText,
                description: row[safe: 7]?.asText,
                whenClause: row[safe: 6]?.asText,
                actionType: row[safe: 8]?.asText,
                status: row[safe: 5]?.asText,
                body: body
            ))
            var attributes: [PluginObjectAttribute] = []
            if let whenClause = row[safe: 6]?.asText, !whenClause.isEmpty {
                attributes.append(PluginObjectAttribute(label: "When", value: whenClause))
            }
            return PluginTriggerInfo(
                name: name,
                table: row[safe: 1]?.asText,
                schema: owner ?? schema,
                timing: OracleObjectQueries.timing(fromTriggerType: triggerType),
                event: row[safe: 4]?.asText ?? "",
                orientation: OracleObjectQueries.orientation(fromTriggerType: triggerType),
                statement: body ?? definition,
                definition: definition,
                enabled: (row[safe: 5]?.asText ?? "").uppercased() == "ENABLED",
                attributes: attributes
            )
        }
    }

    // MARK: - Principals

    // A schema is what the driver lists as a database, so a table's scope is `.table(database: owner, schema: nil)`.
    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        let access = try await dictionaryAccess()
        let users = OraclePrincipalQueries.parseUsers(
            try await textRows(OraclePrincipalQueries.users(access: access, release: release))
        )
        let roles = OraclePrincipalQueries.parseNames(try await textRows(OraclePrincipalQueries.roles(access: access)))
        let grants = OraclePrincipalQueries.parseRoleGrants(
            try await textRows(OraclePrincipalQueries.roleGrants(access: access))
        )
        let roleNames = Set(roles)
        principalState.withLock { $0.roles = roleNames }

        var memberOf: [String: Set<String>] = [:]
        for grant in grants where roleNames.contains(grant.role) {
            memberOf[grant.grantee, default: []].insert(grant.role)
        }

        let userInfos = users.filter { !roleNames.contains($0.name) }.map { user in
            PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: user.name),
                canLogin: !user.isLocked,
                memberOf: (memberOf[user.name] ?? []).sorted()
            )
        }
        let roleInfos = roles.map { role in
            PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: role),
                isRole: true,
                canLogin: false,
                memberOf: (memberOf[role] ?? []).sorted()
            )
        }
        return userInfos + roleInfos
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        let access = try await dictionaryAccess()
        let name = principal.name
        let system = OraclePrincipalQueries.parseSystemPrivileges(
            try await textRows(OraclePrincipalQueries.systemPrivileges(grantee: name, access: access))
        )
        let objects = OraclePrincipalQueries.parseObjectPrivileges(
            try await textRows(OraclePrincipalQueries.objectPrivileges(grantee: name, access: access))
        )
        let columns = OraclePrincipalQueries.parseColumnPrivileges(
            try await textRows(OraclePrincipalQueries.columnPrivileges(grantee: name, access: access))
        )
        return (system + objects + columns).map(Self.pluginGrant)
    }

    // `roles` are the names `fetchPrincipals` found to be roles, which a grant spells without a privilege keyword.
    static func generateGrantSQL(changeSet: PluginPrincipalChangeSet, roles: Set<String>) -> [String]? {
        guard let grants = oracleGrants(changeSet.grantsToAdd) else { return nil }
        return OraclePrincipalStatements(roles: roles).grantStatements(grants, to: changeSet.principal.name)
    }

    static func generateRevokeSQL(changeSet: PluginPrincipalChangeSet, roles: Set<String>) -> [String]? {
        guard let grants = oracleGrants(changeSet.grantsToRemove) else { return nil }
        return OraclePrincipalStatements(roles: roles).revokeStatements(grants, from: changeSet.principal.name)
    }

    func textRows(_ query: String) async throws -> [[String?]] {
        try await run(query).rows.map { $0.map(\.stringValue) }
    }

    func names(_ query: String) async throws -> [String] {
        OraclePrincipalQueries.parseNames(try await textRows(query))
    }

    // Probed once per connection: an account that cannot read DBA_USERS reads the ALL_ and USER_ views instead.
    private func dictionaryAccess() async throws -> OracleDictionaryAccess {
        if let access = principalState.withLock({ $0.access }) {
            return access
        }
        let access: OracleDictionaryAccess
        do {
            _ = try await run(OraclePrincipalQueries.dbaProbe)
            access = .dba
        } catch let error where coreError(error).map(OraclePrincipalQueries.isMissingView) == true {
            access = .session
        }
        principalState.withLock { $0.access = access }
        return access
    }

    private static func oracleGrants(_ grants: [PluginGrantInfo]) -> [OracleGrant]? {
        var converted: [OracleGrant] = []
        for grant in grants {
            let securable: OracleSecurable
            switch grant.scope {
            case .server:
                securable = .system
            case let .table(owner, _, table), let .column(owner, _, table, _):
                securable = .object(owner: owner, name: table)
            case .database, .schema:
                return nil
            @unknown default:
                return nil
            }
            converted.append(OracleGrant(
                privilege: grant.privilege,
                securable: securable,
                column: grant.scope.columnName,
                isGrantable: grant.isGrantable
            ))
        }
        return converted
    }

    private static func pluginGrant(_ grant: OracleGrant) -> PluginGrantInfo {
        let scope: PluginPrivilegeScope
        switch grant.securable {
        case .system:
            scope = .server
        case let .object(owner, name):
            scope = grant.column.map {
                .column(database: owner, schema: nil, table: name, column: $0)
            } ?? .table(database: owner, schema: nil, table: name)
        }
        return PluginGrantInfo(privilege: grant.privilege, scope: scope, isGrantable: grant.isGrantable)
    }

    // MARK: - Helpers

    private func routineSchema(_ schema: String?) -> String {
        effectiveSchema(schema?.isEmpty == false ? schema : nil)
    }

    // The plugin's catalog reads took their text from the PluginKit cells, so a byte cell reads as no text here too.
    private func cells(_ query: String) async throws -> [[PluginCellValue]] {
        try await run(query).rows.map { $0.map(\.asPluginCell) }
    }

    private static func qualified(_ schema: String, _ name: String) -> String {
        "\(OracleObjectQueries.quoteIdentifier(schema)).\(OracleObjectQueries.quoteIdentifier(name))"
    }
}
