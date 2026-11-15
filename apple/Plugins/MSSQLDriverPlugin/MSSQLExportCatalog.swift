import Foundation
import os
import TableProMSSQLCore
import TableProPluginKit

nonisolated struct MSSQLPrincipalState: Sendable {
    var directory: MSSQLPrincipalDirectory?
    var catalog: PluginPrivilegeCatalog?
}

nonisolated struct MSSQLExportCatalogError: PluginDriverError {
    let pluginErrorMessage: String

    init(_ refusal: MSSQLDefinitionRefusal) {
        pluginErrorMessage = refusal.reason
    }
}

// The catalog reads both apps run for SQL Server, over whatever connection the caller hands in.
nonisolated struct MSSQLExportCatalog: Sendable {
    typealias Run = @Sendable (String) async throws -> PluginQueryResult

    let run: Run
    let currentSchema: String
    let principalState: OSAllocatedUnfairLock<MSSQLPrincipalState>

    init(
        run: @escaping Run,
        currentSchema: String,
        principalState: OSAllocatedUnfairLock<MSSQLPrincipalState> = OSAllocatedUnfairLock(
            initialState: MSSQLPrincipalState()
        )
    ) {
        self.run = run
        self.currentSchema = currentSchema
        self.principalState = principalState
    }

    static let tableDDLIncludesForeignKeys = true

    // An empty schema is the current one, never a schema named "".
    static func effectiveSchema(_ schema: String?, current: String) -> String {
        guard let schema, !schema.isEmpty else { return current }
        return schema
    }

    func effectiveSchema(_ schema: String?) -> String {
        Self.effectiveSchema(schema, current: currentSchema)
    }

    func textRows(_ query: String) async throws -> [[String?]] {
        try await run(query).rows.map { $0.map(\.asText) }
    }

    // MARK: - Routines

    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let resolvedSchema = effectiveSchema(schema)
        let result = try await run(MSSQLObjectQueries.routineList(schema: resolvedSchema))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let objectType = row[safe: 2]?.asText ?? ""
            let isProcedure = MSSQLObjectQueries.routineKind(forObjectType: objectType) == "PROCEDURE"
            var attributes: [PluginObjectAttribute] = []
            attributes.append(PluginObjectAttribute(label: "Object Type", value: objectType.trimmingCharacters(in: .whitespaces)))
            let hasSQLSource = MSSQLObjectQueries.routineHasSQLSource(forObjectType: objectType)
            if row[safe: 3]?.asText == "1" {
                attributes.append(PluginObjectAttribute(label: "Encrypted", value: "YES"))
            } else if hasSQLSource, row[safe: 4]?.asText == "1" {
                attributes.append(PluginObjectAttribute(
                    label: String(localized: "Source"),
                    value: String(localized: "Not readable with your permissions")
                ))
            }
            let parameters = row[safe: 5]?.asText ?? ""
            return PluginRoutineInfo(
                name: name,
                kind: isProcedure ? .procedure : .function,
                schema: row[safe: 1]?.asText ?? resolvedSchema,
                returnType: isProcedure ? nil : row[safe: 6]?.asText,
                language: MSSQLObjectQueries.routineLanguage(forObjectType: objectType),
                argumentSignature: MSSQLRoutineSignature.listed(parameters: parameters, objectType: objectType),
                identity: nil,
                attributes: attributes
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let resolvedSchema = effectiveSchema(routine.schema)
        let query = MSSQLObjectQueries.moduleDefinition(schema: resolvedSchema, name: routine.name)
        let result = try await run(query)
        guard let row = result.rows.first else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        guard let definition = row[safe: 0]?.asText, !definition.isEmpty else {
            let isEncrypted = row[safe: 1]?.asText == "1"
            let hasSQLSource = MSSQLObjectQueries.routineHasSQLSource(forObjectType: row[safe: 2]?.asText ?? "")
            throw isEncrypted || !hasSQLSource
                ? PluginObjectSourceError.unsupported(routine.name)
                : PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        return definition
    }

    // SQL Server routines do not overload, so the signature only says whether a function is a CLR aggregate.
    func generateDropRoutineSQL(name: String, signature: String?, schema: String?, isFunction: Bool) -> String? {
        MSSQLDropStatements.routine(
            schema: effectiveSchema(schema),
            name: name,
            isFunction: isFunction,
            signature: signature
        )
    }

    // MARK: - Triggers

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await triggerList(schema: effectiveSchema(schema), table: nil)
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await triggerList(schema: effectiveSchema(schema), table: table)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await triggerList(schema: effectiveSchema(trigger.schema), table: trigger.table)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.insufficientPrivilege(trigger.name)
        }
        return definition
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        MSSQLDropStatements.trigger(schema: effectiveSchema(schema), name: name)
    }

    // sys.trigger_events has one row per event, so a trigger's events are folded back together in the order listed.
    private func triggerList(schema: String, table: String?) async throws -> [PluginTriggerInfo] {
        let result = try await run(MSSQLObjectQueries.triggerList(schema: schema, table: table))
        var order: [String] = []
        var byKey: [String: (info: PluginTriggerInfo, events: [String])] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText else { continue }
            let owningTable = row[safe: 1]?.asText
            let key = "\(owningTable ?? "")|\(name)"
            let event = row[safe: 4]?.asText ?? ""
            if byKey[key] == nil {
                order.append(key)
                let definition = row[safe: 6]?.asText ?? ""
                byKey[key] = (
                    info: PluginTriggerInfo(
                        name: name,
                        table: owningTable,
                        schema: row[safe: 2]?.asText ?? schema,
                        timing: row[safe: 3]?.asText == "1" ? "INSTEAD OF" : "AFTER",
                        event: "",
                        orientation: "STATEMENT",
                        statement: definition,
                        definition: definition,
                        enabled: row[safe: 5]?.asText != "1",
                        attributes: []
                    ),
                    events: []
                )
            }
            if !event.isEmpty {
                byKey[key]?.events.append(event)
            }
        }
        return order.compactMap { key in
            guard let entry = byKey[key] else { return nil }
            let info = entry.info
            return PluginTriggerInfo(
                name: info.name,
                table: info.table,
                schema: info.schema,
                timing: info.timing,
                event: entry.events.joined(separator: " OR "),
                orientation: info.orientation,
                statement: info.statement,
                definition: info.definition,
                enabled: info.enabled,
                attributes: info.attributes
            )
        }
    }

    // MARK: - Tables and Views

    // A view answers with its own definition: a column over an identity column reports `IsIdentity`.
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let resolvedSchema = effectiveSchema(schema)
        let module = try await storedModule(schema: resolvedSchema, name: table)
        if MSSQLObjectQueries.isView(objectType: module?[safe: 2].flatMap { $0 } ?? "") {
            return try MSSQLObjectQueries.viewSource(row: module, schema: resolvedSchema, name: table)
        }

        let columns = try await columnRows(table: table, schema: schema)
        let keyConstraints = try await textRows(MSSQLSchemaQueries.keyConstraints(schema: resolvedSchema, table: table))
            .compactMap(MSSQLSchemaQueries.parseKeyConstraintRow)
        let checkConstraints = try await textRows(MSSQLSchemaQueries.checkConstraints(schema: resolvedSchema, table: table))
            .compactMap(MSSQLSchemaQueries.parseCheckConstraintRow)
        let foreignKeys = try await foreignKeyRows(table: table, schema: schema)
        let collation = await databaseCollation(forTable: table)
        do {
            return try MSSQLSchemaQueries.createTableStatement(
                schema: resolvedSchema,
                table: table,
                columns: columns,
                keyConstraints: keyConstraints,
                checkConstraints: checkConstraints,
                foreignKeys: foreignKeys,
                databaseCollation: collation
            )
        } catch let refusal as MSSQLDefinitionRefusal {
            throw MSSQLExportCatalogError(refusal)
        }
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let resolvedSchema = effectiveSchema(schema)
        let module = try await storedModule(schema: resolvedSchema, name: view)
        return try MSSQLObjectQueries.viewSource(row: module, schema: resolvedSchema, name: view)
    }

    // Key and UNIQUE indexes come with `fetchTableDDL`; this also re-enables checks the source enforced unchecked.
    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        let resolvedSchema = effectiveSchema(schema)
        let rows = try await textRows(MSSQLSchemaQueries.indexDefinitions(schema: resolvedSchema, table: table))
        let checks = try await textRows(MSSQLSchemaQueries.checkConstraints(schema: resolvedSchema, table: table))
            .compactMap(MSSQLSchemaQueries.parseCheckConstraintRow)
        do {
            return try MSSQLSchemaQueries.indexStatements(rows: rows, schema: resolvedSchema, table: table)
                + MSSQLSchemaQueries.checkConstraintReenableStatements(
                    schema: resolvedSchema, table: table, checkConstraints: checks
                )
        } catch let refusal as MSSQLDefinitionRefusal {
            throw MSSQLExportCatalogError(refusal)
        }
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let result = try await run(MSSQLSchemaQueries.approximateRowCount(schema: effectiveSchema(schema), table: table))
        if let row = result.rows.first, let cell = row.first, let str = cell.asText {
            return Int(str)
        }
        return nil
    }

    // Unread, every column states its collation, which keeps it rather than changing it.
    private func databaseCollation(forTable table: String) async -> String? {
        guard let result = try? await run(MSSQLSchemaQueries.databaseCollation(forTable: table)) else {
            return nil
        }
        return result.rows.first?[safe: 0]?.asText
    }

    private func storedModule(schema: String, name: String) async throws -> [String?]? {
        let result = try await run(MSSQLObjectQueries.moduleDefinition(schema: schema, name: name))
        return result.rows.first.map { $0.map(\.asText) }
    }

    // MARK: - Columns

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await columnRows(table: table, schema: schema).map(\.pluginColumnInfo)
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let result = try await run(MSSQLSchemaQueries.allColumns(schema: effectiveSchema(schema)))
        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            let cells = row.map(\.asText)
            guard let tableName = cells[safe: MSSQLSchemaQueries.allColumnsTableNameIndex] ?? nil,
                  let column = MSSQLSchemaQueries.parseColumnRow(cells) else { continue }
            columnsByTable[tableName, default: []].append(column.pluginColumnInfo)
        }
        return columnsByTable
    }

    private func columnRows(table: String, schema: String?) async throws -> [MSSQLColumnRow] {
        let sql = MSSQLSchemaQueries.namesTemporaryTable(table)
            ? MSSQLSchemaQueries.temporaryColumns(table: table)
            : MSSQLSchemaQueries.columns(schema: effectiveSchema(schema), table: table)
        let result = try await run(sql)
        return result.rows.compactMap { row in
            MSSQLSchemaQueries.parseColumnRow(row.map(\.asText))
        }
    }

    // MARK: - Foreign Keys

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        try await foreignKeyRows(table: table, schema: schema).map(Self.foreignKey)
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let result = try await run(MSSQLSchemaQueries.foreignKeys(schema: effectiveSchema(schema), table: nil))
        var fksByTable: [String: [PluginForeignKeyInfo]] = [:]
        for row in result.rows {
            guard let parsed = MSSQLSchemaQueries.parseForeignKeyRow(row.map { $0.asText }),
                  let table = parsed.table else { continue }
            fksByTable[table, default: []].append(Self.foreignKey(parsed))
        }
        return fksByTable
    }

    private func foreignKeyRows(table: String, schema: String?) async throws -> [MSSQLForeignKeyRow] {
        let sql = MSSQLSchemaQueries.foreignKeys(schema: effectiveSchema(schema), table: table)
        let result = try await run(sql)
        return result.rows.compactMap { row in
            MSSQLSchemaQueries.parseForeignKeyRow(row.map { $0.asText })
        }
    }

    private static func foreignKey(_ row: MSSQLForeignKeyRow) -> PluginForeignKeyInfo {
        PluginForeignKeyInfo(
            name: row.constraintName,
            column: row.columnName,
            referencedTable: row.referencedTable,
            referencedColumn: row.referencedColumn,
            referencedSchema: row.referencedSchema,
            onDelete: row.onDelete,
            onUpdate: row.onUpdate
        )
    }

    // MARK: - User-Defined Types

    // The listing carries no definitions: a table type's statement costs two more reads per type.
    func fetchUserDefinedTypes(schema: String?) async throws -> [PluginUserDefinedTypeInfo] {
        let resolvedSchema = effectiveSchema(schema)
        let result = try await run(MSSQLTypeQueries.userDefinedTypeList(schema: resolvedSchema))
        return result.rows.compactMap { row in
            listedType(from: row, schema: resolvedSchema)
        }
    }

    // Addressed by `user_type_id`, so a type renamed since the listing still resolves.
    func fetchUserDefinedType(_ type: PluginUserDefinedTypeInfo) async throws -> PluginUserDefinedTypeInfo {
        let resolvedSchema = effectiveSchema(type.schema)
        let result = try await run(MSSQLTypeQueries.userDefinedTypeList(schema: resolvedSchema))
        let listed = result.rows.compactMap { listedType(from: $0, schema: resolvedSchema) }
        let match = type.identity.flatMap { identity in listed.first { $0.identity == identity } }
            ?? listed.first { $0.name == type.name }
        guard let match else { throw PluginObjectSourceError.notFound(type.name) }

        do {
            switch match.kind {
            case .tableType:
                return try await tableType(match, schema: resolvedSchema)
            case .clrType:
                return match.withDefinition(MSSQLTypeDefinition.clrStatement(
                    schema: resolvedSchema,
                    name: match.name,
                    assembly: match.attributes.first { $0.label == "Assembly" }?.value,
                    assemblyClass: match.attributes.first { $0.label == "Class" }?.value
                ))
            default:
                return try match.withDefinition(MSSQLTypeDefinition.aliasStatement(
                    schema: resolvedSchema,
                    name: match.name,
                    baseType: match.baseType,
                    isNullable: match.attributes.first { $0.label == "Nullable" }?.value != "NO"
                ))
            }
        } catch let refusal as MSSQLDefinitionRefusal {
            throw MSSQLExportCatalogError(refusal)
        }
    }

    private func tableType(
        _ type: PluginUserDefinedTypeInfo,
        schema: String
    ) async throws -> PluginUserDefinedTypeInfo {
        let columnRows = try await textRows(MSSQLTypeQueries.tableTypeColumns(schema: schema, name: type.name))
        let indexRows = try await textRows(MSSQLTypeQueries.tableTypeIndexes(schema: schema, name: type.name))
        let checkRows = try await textRows(MSSQLTypeQueries.tableTypeCheckConstraints(schema: schema, name: type.name))
        let collation = try? await run(MSSQLTypeQueries.databaseCollation).rows.first?[safe: 0]?.asText

        let columns = MSSQLTypeDefinition.columns(fromRows: columnRows)
        let definition = try MSSQLTypeDefinition.tableStatement(
            schema: schema,
            name: type.name,
            columns: columns,
            indexes: MSSQLTypeDefinition.indexes(fromRows: indexRows),
            checkConstraints: MSSQLTypeDefinition.checkConstraints(fromRows: checkRows),
            isMemoryOptimized: type.attributes.contains { $0.label == "Memory Optimized" && $0.value == "YES" },
            databaseCollation: collation ?? nil
        )

        return PluginUserDefinedTypeInfo(
            name: type.name,
            kind: .tableType,
            schema: schema,
            identity: type.identity,
            fields: columns.map {
                PluginUserDefinedTypeField(name: $0.name, type: $0.type ?? "", collation: $0.collation)
            },
            columnTypeSpelling: type.columnTypeSpelling,
            definition: definition,
            attributes: type.attributes
        )
    }

    private func listedType(from row: [PluginCellValue], schema: String) -> PluginUserDefinedTypeInfo? {
        guard let name = row[safe: 0]?.asText else { return nil }
        let kindCode = row[safe: 3]?.asText ?? ""
        let kind: PluginUserDefinedTypeKind = switch MSSQLTypeQueries.Kind(rawValue: kindCode) {
        case .table: .tableType
        case .clr: .clrType
        default: .aliasType
        }

        var attributes: [PluginObjectAttribute] = []
        if kind == .aliasType {
            attributes.append(PluginObjectAttribute(
                label: "Nullable",
                value: row[safe: 5]?.asText == "1" ? "YES" : "NO"
            ))
        }
        if let collation = row[safe: 6]?.asText, !collation.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Collation", value: collation))
        }
        if let assembly = row[safe: 7]?.asText, !assembly.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Assembly", value: assembly))
        }
        if let assemblyClass = row[safe: 8]?.asText, !assemblyClass.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Class", value: assemblyClass))
        }
        if kind == .tableType, row[safe: 9]?.asText == "1" {
            attributes.append(PluginObjectAttribute(label: "Memory Optimized", value: "YES"))
        }

        return PluginUserDefinedTypeInfo(
            name: name,
            kind: kind,
            schema: row[safe: 1]?.asText ?? schema,
            identity: row[safe: 2]?.asText,
            baseType: row[safe: 4]?.asText,
            columnTypeSpelling: Self.columnTypeSpelling(kind: kind, schema: row[safe: 1]?.asText ?? schema, name: name),
            attributes: attributes
        )
    }

    // A table type is never a column type, so the column picker gets no spelling for it.
    private static func columnTypeSpelling(kind: PluginUserDefinedTypeKind, schema: String, name: String) -> String? {
        guard kind != .tableType else { return nil }
        return "\(MSSQLTypeDefinition.bracketed(schema)).\(MSSQLTypeDefinition.bracketed(name))"
    }

    // MARK: - Principals

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        try await loadPrincipalDirectory().entries.map { entry in
            PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: entry.name),
                isRole: entry.kind.isRole,
                canLogin: !entry.kind.isRole && entry.isEnabled,
                memberOf: entry.memberOf
            )
        }
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        let directory = try await principalDirectory()
        var grants: [MSSQLGrant] = []
        switch directory.kind(of: principal.name) {
        case let .login(user):
            grants += try await serverGrants(principal.name)
            if let user {
                grants += try await databaseGrants(user, database: directory.database)
            }
        case .serverRole:
            grants += try await serverGrants(principal.name)
        case .databaseRole, .databaseUser:
            grants += try await databaseGrants(principal.name, database: directory.database)
        case nil:
            return []
        }
        return grants.map { Self.pluginGrant($0, database: directory.database) }
    }

    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        guard let grants = mssqlGrants(changeSet.grantsToAdd) else { return nil }
        return principalStatements.grantStatements(grants, to: changeSet.principal.name)
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        guard let grants = mssqlGrants(changeSet.grantsToRemove) else { return nil }
        return principalStatements.revokeStatements(grants, from: changeSet.principal.name)
    }

    var principalStatements: MSSQLPrincipalStatements {
        MSSQLPrincipalStatements(directory: principalState.withLock { $0.directory })
    }

    func principalDirectory() async throws -> MSSQLPrincipalDirectory {
        if let cached = principalState.withLock({ $0.directory }) {
            return cached
        }
        return try await loadPrincipalDirectory()
    }

    func names(_ query: String) async throws -> [String] {
        MSSQLPrincipalQueries.parseNames(try await textRows(query))
    }

    private func loadPrincipalDirectory() async throws -> MSSQLPrincipalDirectory {
        let database = try await names(MSSQLPrincipalQueries.currentDatabase).first ?? ""
        let directory = MSSQLPrincipalDirectory(
            database: database,
            logins: MSSQLPrincipalQueries.parseLogins(try await textRows(MSSQLPrincipalQueries.logins(database: database))),
            serverRoles: MSSQLPrincipalQueries.parseNames(try await textRows(MSSQLPrincipalQueries.serverRoles)),
            databasePrincipals: MSSQLPrincipalQueries.parseDatabasePrincipals(
                try await textRows(MSSQLPrincipalQueries.databasePrincipals(database: database))
            ),
            serverMemberships: MSSQLPrincipalQueries.parseMemberships(
                try await textRows(MSSQLPrincipalQueries.serverRoleMembers)
            ),
            databaseMemberships: MSSQLPrincipalQueries.parseMemberships(
                try await textRows(MSSQLPrincipalQueries.databaseRoleMembers(database: database))
            )
        )
        principalState.withLock { $0.directory = directory }
        return directory
    }

    private func serverGrants(_ name: String) async throws -> [MSSQLGrant] {
        MSSQLPrincipalQueries.parseServerPermissions(
            try await textRows(MSSQLPrincipalQueries.serverPermissions(grantee: name))
        )
    }

    private func databaseGrants(_ name: String, database: String) async throws -> [MSSQLGrant] {
        MSSQLPrincipalQueries.parseDatabasePermissions(
            try await textRows(MSSQLPrincipalQueries.databasePermissions(grantee: name, database: database))
        )
    }

    // Statements run in the database the list was read from, so a scope naming another one is refused.
    private func mssqlGrants(_ grants: [PluginGrantInfo]) -> [MSSQLGrant]? {
        let database = principalState.withLock { $0.directory?.database }
        var converted: [MSSQLGrant] = []
        for grant in grants {
            if let database, let scopeDatabase = grant.scope.databaseName, scopeDatabase != database {
                return nil
            }
            let securable: MSSQLSecurable
            switch grant.scope {
            case .server:
                securable = .server
            case .database:
                securable = .database
            case let .schema(_, schema):
                securable = .schema(schema)
            case let .table(_, schema, table), let .column(_, schema, table, _):
                securable = .object(schema: effectiveSchema(schema), name: table)
            @unknown default:
                return nil
            }
            converted.append(MSSQLGrant(
                permission: grant.privilege,
                securable: securable,
                column: grant.scope.columnName,
                withGrantOption: grant.isGrantable
            ))
        }
        return converted
    }

    private static func pluginGrant(_ grant: MSSQLGrant, database: String) -> PluginGrantInfo {
        let scope: PluginPrivilegeScope
        switch grant.securable {
        case .server:
            scope = .server
        case .database:
            scope = .database(database)
        case let .schema(schema):
            scope = .schema(database: database, schema: schema)
        case let .object(schema, name):
            scope = grant.column.map {
                .column(database: database, schema: schema, table: name, column: $0)
            } ?? .table(database: database, schema: schema, table: name)
        }
        return PluginGrantInfo(privilege: grant.permission, scope: scope, isGrantable: grant.withGrantOption)
    }
}

nonisolated extension MSSQLColumnRow {
    var pluginColumnInfo: PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: displayType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            defaultValue: defaultValue,
            extra: isIdentity ? "IDENTITY" : nil,
            collation: collation,
            identityKind: isIdentity ? .always : nil,
            isGenerated: isGenerated
        )
    }
}

nonisolated private extension PluginUserDefinedTypeInfo {
    func withDefinition(_ definition: String) -> PluginUserDefinedTypeInfo {
        PluginUserDefinedTypeInfo(
            name: name,
            kind: kind,
            schema: schema,
            identity: identity,
            enumLabels: enumLabels,
            fields: fields,
            baseType: baseType,
            columnTypeSpelling: columnTypeSpelling,
            definition: definition,
            attributes: attributes
        )
    }
}
