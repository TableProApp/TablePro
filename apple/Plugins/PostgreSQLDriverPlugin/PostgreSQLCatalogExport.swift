//
//  PostgreSQLCatalogExport.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProLogRedaction
import TableProPluginKit
import TableProPostgreSQLCore

// The catalog reads and statements an export needs, over whichever connection runs them. The plugin driver and the
// iOS driver each build one with their own read.
nonisolated struct PostgreSQLCatalogExport: Sendable {
    // `namesRelativeTo` nil runs the read with only pg_catalog on the path; a schema puts that schema first.
    typealias Read = @Sendable (_ statement: String, _ namesRelativeTo: String?) async throws -> [[PluginCellValue]]

    static let tableDDLIncludesForeignKeys = false

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "PostgreSQLPluginDriver")
    private static let sequenceLogger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "Sequences")

    let read: Read
    let currentSchema: String
    // The server version the session resolved: what the reads' column choices follow.
    let capabilities: PostgreSQLCapabilities
    // The reported version, read as modern when unknown: what the listing reads follow.
    let catalogCapabilities: PostgreSQLCapabilities
    let catalogPresence: PostgreSQLCatalogPresence?

    init(
        read: @escaping Read,
        currentSchema: String,
        capabilities: PostgreSQLCapabilities,
        catalogCapabilities: PostgreSQLCapabilities,
        catalogPresence: PostgreSQLCatalogPresence?
    ) {
        self.read = read
        self.currentSchema = currentSchema
        self.capabilities = capabilities
        self.catalogCapabilities = catalogCapabilities
        self.catalogPresence = catalogPresence
    }

    var includesMaterializedViews: Bool {
        catalogPresence?.hasMaterializedViews ?? capabilities.hasMaterializedViewsCatalog
    }

    var includesSequencesCatalog: Bool {
        catalogPresence?.hasSequences ?? capabilities.hasSequencesCatalog
    }

    private func rows(_ statement: String, namesRelativeTo schema: String? = nil) async throws -> [[PluginCellValue]] {
        try await read(statement, schema)
    }

    // MARK: - Routines and triggers

    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let resolvedSchema = schema ?? currentSchema
        let query = PostgreSQLObjectQueries.routineList(schema: resolvedSchema, capabilities: catalogCapabilities)
        return try await rows(query).compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 1]?.asText else { return nil }
            let kind: PluginRoutineKind = row[safe: 6]?.asText == "p" ? .procedure : .function
            return PluginRoutineInfo(
                name: name,
                kind: kind,
                schema: row[safe: 2]?.asText ?? resolvedSchema,
                returnType: row[safe: 4]?.asText,
                language: row[safe: 5]?.asText,
                argumentSignature: row[safe: 3]?.asText,
                identity: row[safe: 0]?.asText,
                attributes: Self.routineAttributes(row)
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let resolvedSchema = routine.schema ?? currentSchema
        let query: String
        if let identity = routine.identity, !identity.isEmpty, Int(identity) != nil {
            query = PostgreSQLObjectQueries.routineDefinition(identity: identity)
        } else {
            query = PostgreSQLObjectQueries.routineDefinitionByName(
                name: routine.name,
                schema: resolvedSchema,
                arguments: routine.argumentSignature
            )
        }
        guard let ddl = try await rows(query).first?[safe: 0]?.asText, !ddl.isEmpty else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        return ddl
    }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        let resolvedSchema = schema ?? currentSchema
        let query = PostgreSQLObjectQueries.triggerList(schema: resolvedSchema, table: nil)
        return try await rows(query).compactMap { Self.trigger(from: $0, fallbackSchema: resolvedSchema) }
    }

    // The schema-wide builder with one more predicate, so one table's triggers never disagree with the list.
    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        let resolvedSchema = schema ?? currentSchema
        let query = PostgreSQLObjectQueries.triggerList(schema: resolvedSchema, table: table)
        let result = try await rows(query)
        let triggers = result.compactMap { Self.trigger(from: $0, fallbackSchema: resolvedSchema) }
        Self.logger.info("[trigger] postgres fetchTriggers schema=\(resolvedSchema, privacy: .private(mask: .hash)) table=\(table, privacy: .private(mask: .hash)) rows=\(result.count) parsed=\(triggers.count)")
        return triggers
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let resolvedSchema = trigger.schema ?? currentSchema
        let query = PostgreSQLObjectQueries.triggerList(schema: resolvedSchema, table: trigger.table)
        let match = try await rows(query)
            .compactMap { Self.trigger(from: $0, fallbackSchema: resolvedSchema) }
            .first { $0.name == trigger.name }
        guard let definition = match?.definition, !definition.isEmpty else {
            throw PluginObjectSourceError.notFound(trigger.name)
        }
        return definition
    }

    static func trigger(from row: [PluginCellValue], fallbackSchema: String) -> PluginTriggerInfo? {
        guard let name = row[safe: 0]?.asText,
              let definition = row[safe: 7]?.asText
        else { return nil }
        var attributes: [PluginObjectAttribute] = []
        if let owner = row[safe: 8]?.asText, !owner.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Owner", value: owner))
        }
        return PluginTriggerInfo(
            name: name,
            table: row[safe: 1]?.asText,
            schema: row[safe: 2]?.asText ?? fallbackSchema,
            timing: row[safe: 3]?.asText ?? "",
            event: row[safe: 4]?.asText ?? "",
            orientation: row[safe: 5]?.asText,
            statement: definition,
            definition: definition,
            enabled: PostgreSQLCatalogBoolean.isTrue(row[safe: 6]?.asText),
            attributes: attributes
        )
    }

    private static func routineAttributes(_ row: [PluginCellValue]) -> [PluginObjectAttribute] {
        var attributes: [PluginObjectAttribute] = []
        if let volatility = row[safe: 7]?.asText, !volatility.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Volatility", value: volatility))
        }
        if let security = row[safe: 8]?.asText, !security.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Security", value: security))
        }
        if let owner = row[safe: 9]?.asText, !owner.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Owner", value: owner))
        }
        return attributes
    }

    // PostgreSQL allows `f(integer)` and `f(text)` in one schema, so a drop that names only `f` is ambiguous.
    func generateDropRoutineSQL(name: String, signature: String?, schema: String?, isFunction: Bool) -> String {
        let keyword = isFunction ? "FUNCTION" : "PROCEDURE"
        let arguments = (signature ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let qualified = PostgreSQLObjectQueries.qualifiedName(schema: schema ?? currentSchema, name: name)
        return "DROP \(keyword) IF EXISTS \(qualified)\(arguments)"
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String {
        let qualified = PostgreSQLObjectQueries.qualifiedName(schema: schema ?? currentSchema, name: table)
        return "DROP TRIGGER IF EXISTS \(PostgreSQLObjectQueries.quoteIdentifier(name)) ON \(qualified)"
    }

    // MARK: - Types

    func fetchUserDefinedTypes(schema: String?) async throws -> [PluginUserDefinedTypeInfo] {
        let query = PostgreSQLObjectQueries.userDefinedTypeList(
            schema: schema ?? currentSchema,
            identity: nil,
            capabilities: catalogCapabilities
        )
        return try await rows(query)
            .compactMap(PostgreSQLTypeDefinition.record(from:))
            .map(PostgreSQLTypeDefinition.info(from:))
    }

    // An identity is the oid this catalog handed out, looked up without a schema predicate because a moved type keeps
    // it; one that is not an oid is refused rather than widened into a listing.
    func fetchUserDefinedType(_ type: PluginUserDefinedTypeInfo) async throws -> PluginUserDefinedTypeInfo {
        if let identity = type.identity {
            guard let oid = UInt32(identity) else { throw PluginObjectSourceError.notFound(type.name) }
            let query = PostgreSQLObjectQueries.userDefinedTypeList(
                schema: nil,
                identity: String(oid),
                capabilities: catalogCapabilities
            )
            let match = try await rows(query)
                .compactMap(PostgreSQLTypeDefinition.record(from:))
                .first { $0.identity == String(oid) }
            guard let match else { throw PluginObjectSourceError.notFound(type.name) }
            return PostgreSQLTypeDefinition.info(from: match)
        }
        let query = PostgreSQLObjectQueries.userDefinedTypeList(
            schema: type.schema ?? currentSchema,
            identity: nil,
            capabilities: catalogCapabilities
        )
        let match = try await rows(query)
            .compactMap(PostgreSQLTypeDefinition.record(from:))
            .first { $0.name == type.name }
        guard let match else { throw PluginObjectSourceError.notFound(type.name) }
        return PostgreSQLTypeDefinition.info(from: match)
    }

    func fetchDependentTypes(table: String, schema: String?) async throws -> [(name: String, labels: [String])] {
        let query = PostgreSQLSchemaQueries.dependentEnumTypes(schema: schema ?? currentSchema, table: table)
        return try await rows(query).compactMap { row -> (name: String, labels: [String])? in
            guard let typeName = row[0].asText, let labelsStr = row[1].asText else { return nil }
            return (name: typeName, labels: PostgreSQLTextArray.values(labelsStr))
        }
    }

    // MARK: - Sequences

    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)] {
        let definitions = try await sequenceDefinitions(schema: schema ?? currentSchema, dependentOnTable: table)
        return definitions.map { (name: $0.name, ddl: $0.ddl) }
    }

    func fetchSequences(schema: String?) async throws -> [PluginSequenceInfo] {
        let schemaName = schema ?? currentSchema
        let definitions = try await sequenceDefinitions(schema: schemaName, dependentOnTable: nil)
        return definitions.map { PluginSequenceInfo(name: $0.name, ddl: $0.ddl, schema: schemaName) }
    }

    func fetchSequenceDetails(sequence: String, schema: String?) async throws -> PluginSequenceDetails? {
        let schemaName = schema ?? currentSchema
        let definitions = try await sequenceDefinitions(schema: schemaName, dependentOnTable: nil, named: sequence)
        guard let definition = definitions.first else { return nil }
        return definition.details(schema: schemaName, position: await position(schema: schemaName, sequence: sequence))
    }

    func sequenceDDL(sequence: String, schema: String) async throws -> String? {
        let definitions = try await sequenceDefinitions(schema: schema, dependentOnTable: nil, named: sequence)
        return definitions.first?.qualifiedDDL(schema: schema)
    }

    // Needs SELECT on the sequence; a role without it gets no position rather than a guess.
    private func position(schema: String, sequence: String) async -> PostgreSQLSequencePosition? {
        do {
            let query = PostgreSQLSequencePosition.query(schema: schema, sequence: sequence)
            return PostgreSQLSequencePosition(row: try await rows(query).first)
        } catch {
            Self.sequenceLogger.debug(
                "Sequence position unavailable for \(sequence, privacy: .private(mask: .hash)): \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func sequenceDefinitions(
        schema: String,
        dependentOnTable table: String?,
        named sequence: String? = nil
    ) async throws -> [PostgreSQLSequenceDefinition] {
        let source = PostgreSQLSequenceQueries.source(hasSequencesCatalog: includesSequencesCatalog)
        let listing = try await rows(
            PostgreSQLSequenceQueries.sequenceList(schema: schema, dependentOnTable: table, source: source, named: sequence)
        )
        var definitions: [PostgreSQLSequenceDefinition] = []
        for definition in PostgreSQLSequenceQueries.definitions(from: listing) {
            guard definition.needsLastValueRead else {
                definitions.append(definition)
                continue
            }
            definitions.append(definition.withLastValue(await lastValue(schema: schema, sequence: definition.name)))
        }
        return definitions
    }

    private func lastValue(schema: String, sequence: String) async -> String? {
        do {
            let query = PostgreSQLSequenceQueries.lastValue(schema: schema, sequence: sequence)
            return try await rows(query).first?[safe: 0]?.asText
        } catch {
            Self.sequenceLogger.debug(
                "Sequence last value unavailable for \(sequence, privacy: .private(mask: .hash)): \(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - Columns

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let resolvedSchema = schema ?? currentSchema
        let catalog = try await fetchTypeCatalog(schema: resolvedSchema, table: table)
        let query = PostgreSQLSchemaQueries.columnsQuery(
            schema: resolvedSchema,
            table: table,
            capabilities: capabilities,
            includeMaterializedViews: includesMaterializedViews
        )
        let result = try await rows(query)
        let spellings = try await fetchColumnSpellings(schema: resolvedSchema, table: table)[table] ?? [:]
        let columnDDL = try await fetchColumnDDL(schema: resolvedSchema, table: table)[table] ?? [:]
        return result.compactMap { row in
            Self.column(row, tableNameOffset: 0, catalog: catalog, spellings: spellings, columnDDL: columnDDL)
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let resolvedSchema = schema ?? currentSchema
        let catalog = try await fetchTypeCatalog(schema: resolvedSchema, table: nil)
        let query = PostgreSQLSchemaQueries.columnsQuery(
            schema: resolvedSchema,
            table: nil,
            capabilities: capabilities,
            includeMaterializedViews: includesMaterializedViews
        )
        let result = try await rows(query)
        let spellings = try await fetchColumnSpellings(schema: resolvedSchema, table: nil)
        let columnDDL = try await fetchColumnDDL(schema: resolvedSchema, table: nil)
        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result {
            guard row.count >= 5, let tableName = row[0].asText else { continue }
            let tableDDL = columnDDL[tableName] ?? [:]
            let tableSpellings = spellings[tableName] ?? [:]
            if let column = Self.column(
                row, tableNameOffset: 1, catalog: catalog, spellings: tableSpellings, columnDDL: tableDDL
            ) {
                allColumns[tableName, default: []].append(column)
            }
        }
        return allColumns
    }

    private func fetchColumnSpellings(
        schema: String,
        table: String?
    ) async throws -> [String: [String: PostgreSQLColumnSpelling]] {
        let query = PostgreSQLSchemaQueries.columnSpellingQuery(schema: schema, table: table, capabilities: capabilities)
        return PostgreSQLSchemaQueries.columnSpellings(rows: try await rows(query, namesRelativeTo: schema))
    }

    private func fetchColumnDDL(
        schema: String,
        table: String?
    ) async throws -> [String: [String: PostgreSQLCatalogColumnDDL]] {
        let query = PostgreSQLSchemaQueries.columnDDLQuery(schema: schema, table: table, capabilities: capabilities)
        return PostgreSQLSchemaQueries.columnDDL(rows: try await rows(query))
    }

    private func fetchEnumLabelMap(schema: String, table: String?) async throws -> [String: [String]] {
        var map: [String: [String]] = [:]
        for row in try await rows(PostgreSQLSchemaQueries.enumLabelQuery(schema: schema, table: table)) {
            guard let schemaName = row[safe: 0]?.asText,
                  let typeName = row[safe: 1]?.asText else { continue }
            let key = PostgresColumnTypeResolver.qualifiedName(schema: schemaName, name: typeName)
            var labels = map[key] ?? []
            if let label = row[safe: 2]?.asText {
                labels.append(label)
            }
            map[key] = labels
        }
        return map
    }

    private func fetchArrayTypeMap(schema: String, table: String?) async throws -> [String: PostgresArrayTypeInfo] {
        var map: [String: PostgresArrayTypeInfo] = [:]
        for row in try await rows(PostgreSQLSchemaQueries.arrayTypeQuery(schema: schema, table: table)) {
            guard let schemaName = row[safe: 0]?.asText,
                  let arrayTypeName = row[safe: 1]?.asText,
                  let elementTypeName = row[safe: 2]?.asText,
                  let elementKind = row[safe: 3]?.asText?.first else { continue }
            let key = PostgresColumnTypeResolver.qualifiedName(schema: schemaName, name: arrayTypeName)
            map[key] = PostgresArrayTypeInfo(elementTypeName: elementTypeName, elementTypeKind: elementKind)
        }
        return map
    }

    // Scoped to the types the read's own columns use and read fresh: a cache goes stale on the next `CREATE TYPE`.
    private func fetchTypeCatalog(schema: String, table: String?) async throws -> PostgresTypeCatalog {
        let enumLabels = try await fetchEnumLabelMap(schema: schema, table: table)
        let arrayTypes = try await fetchArrayTypeMap(schema: schema, table: table)
        return PostgresTypeCatalog(enumLabels: enumLabels, arrayTypes: arrayTypes)
    }

    private static func column(
        _ row: [PluginCellValue],
        tableNameOffset: Int,
        catalog: PostgresTypeCatalog,
        spellings: [String: PostgreSQLColumnSpelling],
        columnDDL: [String: PostgreSQLCatalogColumnDDL]
    ) -> PluginColumnInfo? {
        let nameIdx = tableNameOffset
        let typeIdx = tableNameOffset + 1
        let nullableIdx = tableNameOffset + 2
        let collationIdx = tableNameOffset + 4
        let commentIdx = tableNameOffset + 5
        let udtIdx = tableNameOffset + 6
        let pkIdx = tableNameOffset + 7
        let identityIdx = tableNameOffset + 8
        let generatedIdx = tableNameOffset + 9
        let udtSchemaIdx = tableNameOffset + 10
        let domainNameIdx = tableNameOffset + 13

        guard row.count > typeIdx,
              let name = row[nameIdx].asText,
              let rawDataType = row[typeIdx].asText
        else { return nil }
        let spelling = spellings[name]

        let udtName = row.count > udtIdx ? row[udtIdx].asText : nil
        let udtSchema = row.count > udtSchemaIdx ? row[udtSchemaIdx].asText : nil
        let resolution = PostgresColumnTypeResolver.resolve(
            rawDataType: rawDataType,
            udtSchema: udtSchema,
            udtName: udtName,
            enumLabelsByQualifiedName: catalog.enumLabels,
            arrayTypesByQualifiedName: catalog.arrayTypes
        )
        let typeSpelling = PostgreSQLColumnTypeSpelling.resolve(
            declaredType: spelling?.declaredType,
            informationSchemaType: rawDataType,
            domainName: row.count > domainNameIdx ? row[domainNameIdx].asText : nil,
            udtSchema: udtSchema,
            resolved: resolution
        )

        let isNullable = row.count > nullableIdx && row[nullableIdx].asText == "YES"
        let collation = row.count > collationIdx ? row[collationIdx].asText : nil
        let comment = row.count > commentIdx ? row[commentIdx].asText : nil
        let isPk = row.count > pkIdx && row[pkIdx].asText == "YES"
        let attidentity = row.count > identityIdx ? row[identityIdx].asText : nil
        let attgenerated = row.count > generatedIdx ? row[generatedIdx].asText : nil

        let charset: String? = {
            guard let coll = collation, coll.contains(".") else { return nil }
            return coll.components(separatedBy: ".").last
        }()

        return PluginColumnInfo(
            name: name,
            dataType: typeSpelling.dataType,
            isNullable: isNullable,
            isPrimaryKey: isPk,
            defaultValue: spelling?.defaultValue,
            charset: charset,
            collation: collation,
            comment: comment?.isEmpty == false ? comment : nil,
            identityKind: identityKind(attidentity),
            isGenerated: attgenerated == "s" || attgenerated == "v",
            allowedValues: resolution.allowedValues,
            generationExpression: spelling?.generationExpression,
            generationKind: generationKind(attgenerated),
            ddlSpelling: columnDDL[name]?.typeSpelling,
            ddlDefault: columnDDL[name]?.defaultExpression,
            ddlGenerationExpression: columnDDL[name]?.generationExpression,
            ddlCollation: columnDDL[name]?.collation,
            classificationTypeName: typeSpelling.classificationTypeName
        )
    }

    // PostgreSQL 18 added virtual generated columns ('v'); reading only 's' left them writable.
    private static func generationKind(_ attgenerated: String?) -> GenerationKind? {
        switch attgenerated {
        case "s": return .stored
        case "v": return .virtual
        default: return nil
        }
    }

    private static func identityKind(_ attidentity: String?) -> IdentityKind? {
        switch attidentity {
        case "a": return .always
        case "d": return .byDefault
        default: return nil
        }
    }

    // MARK: - Foreign keys

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let resolvedSchema = schema ?? currentSchema
        let query = PostgreSQLForeignKeyQueries.foreignKeyList(
            schema: resolvedSchema, table: table, capabilities: catalogCapabilities
        )
        let result = try await rows(query)
        let foreignKeys = result.compactMap { PostgreSQLForeignKeyRow($0)?.foreignKey }
        Self.logger.info("[fk] postgres fetchForeignKeys schema=\(resolvedSchema, privacy: .private(mask: .hash)) table=\(table, privacy: .private(mask: .hash)) rows=\(result.count) parsed=\(foreignKeys.count)")
        return foreignKeys
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let query = PostgreSQLForeignKeyQueries.foreignKeyList(
            schema: schema ?? currentSchema, table: nil, capabilities: catalogCapabilities
        )
        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for row in try await rows(query) {
            guard let decoded = PostgreSQLForeignKeyRow(row) else { continue }
            grouped[decoded.table, default: []].append(decoded.foreignKey)
        }
        return grouped
    }

    // MARK: - Definitions

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let query = PostgreSQLSchemaQueries.approximateRowCount(schema: schema ?? currentSchema, table: table)
        return PostgreSQLSchemaQueries.rowEstimate(reltuples: try await rows(query).first?[safe: 0]?.asText).map { Int($0) }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let resolvedSchema = schema ?? currentSchema
        let columnsQuery = PostgreSQLSchemaQueries.tableDDLColumnsQuery(
            schema: resolvedSchema, table: table, capabilities: capabilities
        )
        let constraintsQuery = PostgreSQLSchemaQueries.tableDDLConstraintsQuery(schema: resolvedSchema, table: table)
        let shapeQuery = PostgreSQLTableDDL.shapeQuery(schema: resolvedSchema, table: table, capabilities: capabilities)

        async let columnsResult = rows(columnsQuery)
        async let constraintsResult = rows(constraintsQuery)
        async let shapeResult = try? rows(shapeQuery)

        let (cols, cons) = try await (columnsResult, constraintsResult)
        let shapeRows = await shapeResult

        // pg_attribute covers views too, which would otherwise come back as a `CREATE TABLE` of their columns.
        if let relkind = cols.first?[safe: 1]?.asText,
           PostgreSQLViewDefinition.kind(forRelkind: relkind) != nil {
            return try await fetchViewDefinition(view: table, schema: resolvedSchema)
        }
        // A sequence's attributes are its state columns, not a table to recreate.
        if cols.first?[safe: 1]?.asText == "S",
           let ddl = try await sequenceDDL(sequence: table, schema: resolvedSchema) {
            return ddl
        }

        let columnDefs = cols.compactMap { $0[0].asText }
        guard !columnDefs.isEmpty else {
            throw PostgreSQLCatalogReadError(message: "Failed to fetch DDL for table '\(table)'")
        }

        var parts = columnDefs
        parts.append(contentsOf: cons.compactMap { $0[0].asText })

        var shape = PostgreSQLTableDDL.shape(fromRows: shapeRows?.map { $0.map(\.asText) })
        var partitions: [PostgreSQLTableDDL.Partition] = []
        var partitionIndexes: [String] = []
        var partitionComments: [String] = []
        if shape.partitionKey != nil {
            let tree = try await rows(PostgreSQLTableDDL.partitionTreeQuery(schema: resolvedSchema, table: table))
            partitions = tree.compactMap { PostgreSQLTableDDL.partition(from: $0.map(\.asText)) }
            if !partitions.isEmpty {
                async let elementRows = rows(PostgreSQLTableDDL.partitionElementsQuery(
                    schema: resolvedSchema, table: table, scope: .below, capabilities: capabilities
                ))
                async let indexRows = rows(PostgreSQLTableDDL.partitionIndexesQuery(schema: resolvedSchema, table: table))
                async let commentRows = rows(PostgreSQLTableDDL.partitionCommentsQuery(schema: resolvedSchema, table: table))
                let elements = PostgreSQLTableDDL.elementsByPartition(try await elementRows.map { $0.map(\.asText) })
                partitions = partitions.map { partition in
                    var partition = partition
                    partition.elements = elements[partition.name] ?? []
                    return partition
                }
                partitionIndexes = try await indexRows.compactMap { $0.first?.asText }
                partitionComments = PostgreSQLTableDDL.partitionComments(try await commentRows.map { $0.map(\.asText) })
            }
        } else if shape.partitionOf != nil {
            let elementRows = try await rows(PostgreSQLTableDDL.partitionElementsQuery(
                schema: resolvedSchema, table: table, scope: .itself, capabilities: capabilities
            ))
            shape.partitionElements = PostgreSQLTableDDL.elementsByPartition(elementRows.map { $0.map(\.asText) })
                .values.first ?? []
        }

        return PostgreSQLTableDDL.script(
            name: PostgreSQLObjectQueries.qualifiedName(schema: resolvedSchema, name: table),
            definitions: parts,
            shape: shape,
            partitions: partitions,
            partitionIndexes: partitionIndexes,
            partitionComments: partitionComments
        )
    }

    // Rebuilt from the catalog with every name qualified: pg_views lost the options and the check option.
    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let resolvedSchema = schema ?? currentSchema
        let query = PostgreSQLViewDefinition.catalogQuery(name: view, schema: resolvedSchema)
        guard let row = try await rows(query).first,
              let catalogRow = PostgreSQLViewDefinition.parse(row: row.map(\.asText))
        else {
            throw PostgreSQLCatalogReadError(message: "Failed to fetch definition for view '\(view)'")
        }
        return PostgreSQLViewDefinition.statement(name: view, schema: resolvedSchema, row: catalogRow)
    }

    // `pg_get_indexdef` is what pg_dump emits, and it qualifies the table whatever the path holds.
    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        try await fetchStandaloneIndexes(table: table, schema: schema ?? currentSchema).definitions
            .map(PostgreSQLTableDDL.indexCoveringPartitions)
    }

    func fetchStandaloneIndexes(table: String, schema: String) async throws -> PostgreSQLStandaloneIndexes {
        let query = PostgreSQLIndexQueries.standaloneIndexQuery(schema: schema, table: table)
        let indexes = PostgreSQLIndexQueries.standaloneIndexes(rows: try await rows(query))
        if !indexes.invalidNames.isEmpty {
            Self.logger.info(
                "Left out \(indexes.invalidNames.count) invalid index(es) on \(table, privacy: .private(mask: .hash))"
            )
        }
        return indexes
    }

    // A plain read: nothing here is deparsed by the server, so the session's path cannot change the answer.
    func fetchCommentDDL(table: String, schema: String?) async throws -> [String] {
        let resolvedSchema = schema ?? currentSchema
        let query = PostgreSQLCommentStatements.catalogQuery(name: table, schema: resolvedSchema)
        return PostgreSQLCommentStatements.statements(
            name: table,
            schema: resolvedSchema,
            rows: try await rows(query).map { $0.map(\.asText) }
        )
    }

    // MARK: - Principals

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        let memberships = try await fetchMemberships()
        let supportedAttributes = PostgreSQLVersionedStatements.roleAttributes(capabilities: capabilities)
        let query = PostgreSQLPrincipalQueries.principals(includeBypassRLS: capabilities.hasBypassRLS)
        return try await rows(query).compactMap { row -> PluginPrincipalInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let canLogin = PostgreSQLCatalogBoolean.isTrue(row[safe: 1]?.asText)
            let connectionLimit = row[safe: 8]?.asText.flatMap(Int.init)
            return PluginPrincipalInfo(
                ref: PluginPrincipalRef(name: name),
                isRole: !canLogin,
                canLogin: canLogin,
                attributes: Self.decodeAttributes(row: row, supported: supportedAttributes),
                memberOf: memberships[name] ?? [],
                connectionLimit: connectionLimit == -1 ? nil : connectionLimit,
                comment: row[safe: 9]?.asText
            )
        }
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] {
        let role = principal.name
        let database = try await currentDatabaseName()
        let databaseGrants = try await fetchDatabaseGrants(role: role)
        let schemaGrants = try await fetchSchemaGrants(role: role, database: database)
        let tableGrants = try await fetchTableGrants(role: role, database: database)
        let columnGrants = try await fetchColumnGrants(role: role, database: database)
        return databaseGrants + schemaGrants + tableGrants + columnGrants
    }

    func currentDatabaseName() async throws -> String {
        try await rows(PostgreSQLPrincipalQueries.currentDatabase).first?[safe: 0]?.asText ?? ""
    }

    static func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        grantBuilder(for: changeSet.principal).grantStatements(changeSet.grantsToAdd)
    }

    static func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        grantBuilder(for: changeSet.principal).revokeStatements(changeSet.grantsToRemove)
    }

    private static func grantBuilder(for principal: PluginPrincipalRef) -> PluginGrantSQLBuilder {
        PluginGrantSQLBuilder(
            grantee: PostgreSQLObjectQueries.quoteIdentifier(principal.name),
            quoteIdentifier: { PostgreSQLObjectQueries.quoteIdentifier($0) },
            target: { grantTarget(for: $0) }
        )
    }

    private static func grantTarget(for scope: PluginPrivilegeScope) -> String? {
        let quote = PostgreSQLObjectQueries.quoteIdentifier
        switch scope {
        case .server:
            return nil
        case let .database(name):
            return "DATABASE \(quote(name))"
        case let .schema(_, schema):
            return "SCHEMA \(quote(schema))"
        case let .table(_, schema, table), let .column(_, schema, table, _):
            if let schema {
                return "TABLE \(quote(schema)).\(quote(table))"
            }
            return "TABLE \(quote(table))"
        @unknown default:
            return nil
        }
    }

    private func fetchMemberships() async throws -> [String: [String]] {
        var memberships: [String: [String]] = [:]
        for row in try await rows(PostgreSQLPrincipalQueries.memberships) {
            guard let member = row[safe: 0]?.asText,
                  let grantedRole = row[safe: 1]?.asText else { continue }
            memberships[member, default: []].append(grantedRole)
        }
        return memberships
    }

    private func fetchDatabaseGrants(role: String) async throws -> [PluginGrantInfo] {
        try await rows(PostgreSQLPrincipalQueries.databaseGrants(role: role)).compactMap { row -> PluginGrantInfo? in
            guard let database = row[safe: 0]?.asText,
                  let privilege = row[safe: 1]?.asText else { return nil }
            return PluginGrantInfo(
                privilege: privilege,
                scope: .database(database),
                isGrantable: PostgreSQLCatalogBoolean.isTrue(row[safe: 2]?.asText)
            )
        }
    }

    private func fetchSchemaGrants(role: String, database: String) async throws -> [PluginGrantInfo] {
        try await rows(PostgreSQLPrincipalQueries.schemaGrants(role: role)).compactMap { row -> PluginGrantInfo? in
            guard let schema = row[safe: 0]?.asText,
                  let privilege = row[safe: 1]?.asText else { return nil }
            return PluginGrantInfo(
                privilege: privilege,
                scope: .schema(database: database, schema: schema),
                isGrantable: PostgreSQLCatalogBoolean.isTrue(row[safe: 2]?.asText)
            )
        }
    }

    private func fetchTableGrants(role: String, database: String) async throws -> [PluginGrantInfo] {
        try await rows(PostgreSQLPrincipalQueries.tableGrants(role: role)).compactMap { row -> PluginGrantInfo? in
            guard let schema = row[safe: 0]?.asText,
                  let table = row[safe: 1]?.asText,
                  let privilege = row[safe: 2]?.asText else { return nil }
            return PluginGrantInfo(
                privilege: privilege,
                scope: .table(database: database, schema: schema, table: table),
                isGrantable: PostgreSQLCatalogBoolean.isTrue(row[safe: 3]?.asText)
            )
        }
    }

    private func fetchColumnGrants(role: String, database: String) async throws -> [PluginGrantInfo] {
        try await rows(PostgreSQLPrincipalQueries.columnGrants(role: role)).compactMap { row -> PluginGrantInfo? in
            guard let schema = row[safe: 0]?.asText,
                  let table = row[safe: 1]?.asText,
                  let column = row[safe: 2]?.asText,
                  let privilege = row[safe: 3]?.asText else { return nil }
            return PluginGrantInfo(
                privilege: privilege,
                scope: .column(database: database, schema: schema, table: table, column: column),
                isGrantable: PostgreSQLCatalogBoolean.isTrue(row[safe: 4]?.asText)
            )
        }
    }

    private static func decodeAttributes(
        row: [PluginCellValue],
        supported: Set<PostgreSQLRoleAttribute>
    ) -> [PluginPrincipalAttribute] {
        let columnOffsets: [(PostgreSQLRoleAttribute, Int)] = [
            (.superuser, 2),
            (.createdb, 3),
            (.createrole, 4),
            (.replication, 5),
            (.bypassrls, 6),
            (.inherit, 7)
        ]
        return columnOffsets.filter { supported.contains($0.0) }.map { attribute, offset in
            PluginPrincipalAttribute(
                key: attribute.rawValue,
                label: attribute.label,
                isEnabled: PostgreSQLCatalogBoolean.isTrue(row[safe: offset]?.asText)
            )
        }
    }
}

// The settings scope an export opens around its reads, on PostgreSQL's `pg_settings`, `set_config` and savepoints
// (measured on 17.11). CockroachDB and Redshift keep PluginKit's nil scopes.
nonisolated struct PostgreSQLSessionScope: Sendable {
    // Runs one setting statement on the session: inside a transaction under `PostgreSQLSessionScopeSQL`'s savepoint,
    // and throwing `PostgreSQLSessionScopeError.sessionNotIdle` when `requiresIdleSession` is set and it is not idle.
    typealias Setting = @Sendable (
        _ statement: PostgreSQLBoundStatement,
        _ requiresIdleSession: Bool
    ) async throws -> [[PluginCellValue]]

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "PostgreSQLSessionScope")

    let setting: Setting
    let transactionState: @Sendable () async -> PluginSessionTransactionState

    init(
        setting: @escaping Setting,
        transactionState: @escaping @Sendable () async -> PluginSessionTransactionState
    ) {
        self.setting = setting
        self.transactionState = transactionState
    }

    func open(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        switch purpose {
        case .preserve:
            guard let saved = await capture(PostgreSQLSessionScopeSQL.preservedNames),
                  !saved.isEmpty else { return nil }
            return PluginSessionScope(purpose: .preserve, saved: saved, applied: [])
        case .verbatimRead:
            return await openVerbatimRead()
        case .verbatimWrite:
            // What the read pins reads back the same under any settings; nil would make the host drop the read too.
            return PluginSessionScope(purpose: .verbatimWrite, saved: [], applied: [])
        case .relaxedForeignKeys:
            // `session_replication_role = replica` would also stop the target's user triggers, and needs a superuser.
            return nil
        @unknown default:
            return nil
        }
    }

    func close(_ scope: PluginSessionScope) async throws {
        guard !scope.saved.isEmpty else { return }
        try await restoreChanged(scope.saved)
    }

    private func openVerbatimRead() async -> PluginSessionScope? {
        guard PostgreSQLSessionScopeSQL.canOpenReadScope(in: await transactionState()) else {
            Self.logger.info("Read scope not opened: the session has a transaction open")
            return nil
        }
        let requested = PostgreSQLSessionScopeSQL.verbatimReadSettings
        let names = PostgreSQLSessionScopeSQL.verbatimReadNames
        guard let captured = await capture(names),
              let saved = PostgreSQLSessionScopeSQL.completeSettings(captured, names: names),
              let statement = PostgreSQLSessionScopeSQL.setStatement(requested)
        else {
            Self.logger.info("Read scope not opened: the server lacks one of its settings or the capture failed")
            return nil
        }
        do {
            let rows = try await setting(statement, true)
            let applied = PostgreSQLSessionScopeSQL.appliedSettings(
                requested,
                reportedRow: rows.first?.map(\.asText) ?? []
            )
            return PluginSessionScope(purpose: .verbatimRead, saved: saved, applied: applied)
        } catch PostgreSQLSessionScopeError.sessionNotIdle {
            Self.logger.info("Read scope not opened: a transaction opened before its settings were applied")
            return nil
        } catch {
            // One statement outside a transaction: a refusal rolls back all of it, so nothing needs putting back.
            Self.logger.error(
                "Read scope not opened, its settings were refused: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    private func capture(_ names: [String]) async -> [PluginSessionSetting]? {
        guard PostgreSQLSessionScopeSQL.canRestore(in: await transactionState()) else {
            Self.logger.info("Session scope not opened: the session is in an aborted transaction")
            return nil
        }
        do {
            let rows = try await setting(PostgreSQLSessionScopeSQL.captureStatement(names: names), false)
            return PostgreSQLSessionScopeSQL.settings(fromRows: rows.map { $0.map(\.asText) }, names: names)
        } catch {
            Self.logger.error(
                "Session settings capture failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    // Nothing is sent in an aborted transaction: the server would refuse it, and the rollback the session still needs
    // reverts only what the transaction itself set, so the caller is told rather than left to assume.
    private func restoreChanged(_ saved: [PluginSessionSetting]) async throws {
        guard PostgreSQLSessionScopeSQL.canRestore(in: await transactionState()) else {
            Self.logger.error("Session settings not restored: the session is in an aborted transaction")
            throw PostgreSQLSessionScopeError.abortedTransaction
        }
        let names = saved.map(\.name)
        let rows = try await setting(PostgreSQLSessionScopeSQL.captureStatement(names: names), false)
        let current = PostgreSQLSessionScopeSQL.settings(fromRows: rows.map { $0.map(\.asText) }, names: names)

        var refused: [String] = []
        for changed in PostgreSQLSessionScopeSQL.changedSettings(saved: saved, current: current) {
            guard let statement = PostgreSQLSessionScopeSQL.setStatement([changed]) else { continue }
            do {
                _ = try await setting(statement, false)
            } catch {
                refused.append(changed.name)
                Self.logger.error(
                    "Restoring \(changed.name, privacy: .public) failed: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        guard refused.isEmpty else { throw PostgreSQLSessionScopeError.restoreRefused(refused) }
    }
}

// Shown as the driver's own errors are, so a failed read reads the same on either app.
nonisolated struct PostgreSQLCatalogReadError: PluginDriverError {
    let message: String

    var pluginErrorMessage: String { message }
}
