//
//  QueryContextBuilder.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

struct QueryContextInput: Sendable {
    let statement: String
    let scope: DatabaseScope
    let namespaceSlot: EngineNamespaceSlot
    let editorLanguage: EditorLanguage
    let grammar: SQLLexicalGrammar
    let engineName: String
    let serverVersion: String?
    let explainPlan: String?

    init(
        statement: String,
        scope: DatabaseScope,
        namespaceSlot: EngineNamespaceSlot,
        editorLanguage: EditorLanguage,
        grammar: SQLLexicalGrammar,
        engineName: String,
        serverVersion: String? = nil,
        explainPlan: String? = nil
    ) {
        self.statement = statement
        self.scope = scope
        self.namespaceSlot = namespaceSlot
        self.editorLanguage = editorLanguage
        self.grammar = grammar
        self.engineName = engineName
        self.serverVersion = serverVersion
        self.explainPlan = explainPlan
    }
}

extension QueryContextInput {
    @MainActor
    static func make(
        statement: String,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        serverVersion: String?,
        explainPlan: String?
    ) -> QueryContextInput {
        QueryContextInput(
            statement: statement,
            scope: scope,
            namespaceSlot: EngineNamespaceSlot(databaseType: databaseType),
            editorLanguage: PluginManager.shared.editorLanguage(for: databaseType),
            grammar: SQLLexicalResolver.executionGrammar(for: databaseType, connectionId: scope.connectionId),
            engineName: PluginMetadataRegistry.shared.snapshot(for: databaseType)?.displayName ?? databaseType.rawValue,
            serverVersion: serverVersion,
            explainPlan: explainPlan
        )
    }
}

@MainActor
struct QueryContextBuilder {
    nonisolated static let tableLimit = 12
    nonisolated static let columnLimit = 200

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryContextBuilder")

    private let metadata: any ScopedMetadataProviding

    init(metadata: any ScopedMetadataProviding = DatabaseManager.shared) {
        self.metadata = metadata
    }

    func build(_ input: QueryContextInput) async -> QueryContextSnapshot {
        let plan = QueryContextPlan(input: input)
        let inventories = await loadInventories(for: plan.schemaKeys, scope: input.scope)
        let matches = plan.match(against: inventories)

        var described: [QueryContextTable] = []
        for group in matches.groupedTargets {
            guard !Task.isCancelled else { break }
            described.append(contentsOf: await describe(group.targets, schema: group.schema, scope: input.scope))
        }
        let ordered = matches.targets.compactMap { target in
            described.first { $0.name == target.name && $0.schema == target.schema }
        }

        return QueryContextSnapshot(
            engineName: input.engineName,
            languageTag: input.editorLanguage.codeBlockTag,
            serverVersion: input.serverVersion,
            databaseName: input.scope.database,
            schemaName: input.scope.schema,
            tables: ordered,
            notFound: matches.notFound,
            outsideScope: plan.outsideScope,
            notDescribed: matches.notDescribed,
            explainPlan: input.explainPlan
        )
    }

    private func loadInventories(for schemaKeys: [String?], scope: DatabaseScope) async -> [QueryContextSchemaKey: [TableInfo]] {
        var inventories: [QueryContextSchemaKey: [TableInfo]] = [:]
        for schema in schemaKeys {
            guard !Task.isCancelled else { break }
            let tableScope = DatabaseScope(connectionId: scope.connectionId, database: scope.database, schema: schema)
            do {
                inventories[QueryContextSchemaKey(schema)] = try await metadata.withMetadataDriver(scope: tableScope) { driver in
                    try await driver.fetchTables(schema: schema)
                }
            } catch {
                Self.logger.warning("Table list for AI context failed: \(error.publicLogShape, privacy: .public)")
            }
        }
        return inventories
    }

    private func describe(
        _ targets: [QueryContextTarget],
        schema: String?,
        scope: DatabaseScope
    ) async -> [QueryContextTable] {
        let tableScope = DatabaseScope(connectionId: scope.connectionId, database: scope.database, schema: schema)
        do {
            return try await metadata.withMetadataDriver(scope: tableScope) { driver in
                var tables: [QueryContextTable] = []
                for target in targets {
                    if Task.isCancelled { break }
                    tables.append(await Self.describe(target, driver: driver))
                }
                return tables
            }
        } catch {
            let reason = error.localizedDescription
            return targets.map { target in
                QueryContextTable(name: target.name, schema: target.schema, kind: target.kind, content: .unavailable(reason: reason))
            }
        }
    }

    nonisolated private static func describe(_ target: QueryContextTarget, driver: DatabaseDriver) async -> QueryContextTable {
        let columns: [ColumnInfo]
        do {
            columns = try await driver.fetchColumns(table: target.name, schema: target.schema)
        } catch {
            return QueryContextTable(
                name: target.name,
                schema: target.schema,
                kind: target.kind,
                content: .unavailable(reason: error.localizedDescription)
            )
        }

        var indexes: [QueryContextIndex] = []
        var indexesReason: String?
        do {
            indexes = try await driver.fetchIndexes(table: target.name, schema: target.schema).map(QueryContextIndex.init)
        } catch {
            indexesReason = error.localizedDescription
        }

        var foreignKeys: [QueryContextForeignKey] = []
        var foreignKeysReason: String?
        do {
            foreignKeys = QueryContextForeignKey.grouped(
                try await driver.fetchForeignKeys(table: target.name, schema: target.schema)
            )
        } catch {
            foreignKeysReason = error.localizedDescription
        }

        var rowCount = target.rowCount
        if rowCount == nil {
            rowCount = (try? await driver.fetchApproximateRowCount(table: target.name, schema: target.schema)) ?? nil
        }

        return QueryContextTable(
            name: target.name,
            schema: target.schema,
            kind: target.kind,
            content: .described(QueryContextTableStructure(
                columns: columns.map(QueryContextColumn.init),
                indexes: indexes,
                indexesUnavailableReason: indexesReason,
                foreignKeys: foreignKeys,
                foreignKeysUnavailableReason: foreignKeysReason,
                approximateRowCount: rowCount
            ))
        )
    }
}

struct QueryContextSchemaKey: Hashable, Sendable {
    let schema: String?

    init(_ schema: String?) {
        self.schema = schema.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct QueryContextTarget: Equatable, Sendable {
    let name: String
    let schema: String?
    let kind: TableInfo.TableType?
    let rowCount: Int?
}

struct QueryContextPlan {
    struct Candidate: Equatable {
        let written: String
        let name: String
        let schema: String?
        let mustMatchInventory: Bool
    }

    struct Matches {
        let targets: [QueryContextTarget]
        let notFound: [String]
        let notDescribed: [String]

        var groupedTargets: [(schema: String?, targets: [QueryContextTarget])] {
            var order: [QueryContextSchemaKey] = []
            var groups: [QueryContextSchemaKey: [QueryContextTarget]] = [:]
            for target in targets {
                let key = QueryContextSchemaKey(target.schema)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(target)
            }
            return order.map { ($0.schema, groups[$0] ?? []) }
        }
    }

    let candidates: [Candidate]
    let outsideScope: [String]

    init(input: QueryContextInput) {
        let defaultSchema = input.scope.schema
        guard input.editorLanguage == .sql else {
            candidates = QueryTableReferenceResolver.identifierTokens(in: input.statement).map {
                Candidate(written: $0, name: $0, schema: defaultSchema, mustMatchInventory: true)
            }
            outsideScope = []
            return
        }

        var candidates: [Candidate] = []
        var outside: [String] = []
        for reference in QueryTableReferenceResolver.sqlReferences(in: input.statement, grammar: input.grammar) {
            switch Self.placement(of: reference, scope: input.scope, slot: input.namespaceSlot) {
            case .inScope(let schema):
                candidates.append(Candidate(
                    written: reference.displayName,
                    name: reference.name,
                    schema: schema,
                    mustMatchInventory: false
                ))
            case .outside:
                outside.append(reference.displayName)
            }
        }
        self.candidates = candidates
        self.outsideScope = outside
    }

    var schemaKeys: [String?] {
        var seen = Set<QueryContextSchemaKey>()
        var keys: [String?] = []
        for candidate in candidates where seen.insert(QueryContextSchemaKey(candidate.schema)).inserted {
            keys.append(QueryContextSchemaKey(candidate.schema).schema)
        }
        return keys
    }

    func match(against inventories: [QueryContextSchemaKey: [TableInfo]], limit: Int = QueryContextBuilder.tableLimit) -> Matches {
        var targets: [QueryContextTarget] = []
        var notFound: [String] = []
        var notDescribed: [String] = []
        var seen = Set<String>()
        let indexes = inventories.mapValues(InventoryIndex.init)

        for candidate in candidates {
            let key = QueryContextSchemaKey(candidate.schema)
            let target: QueryContextTarget
            if let index = indexes[key] {
                guard let table = index.table(named: candidate.name) else {
                    if !candidate.mustMatchInventory { notFound.append(candidate.written) }
                    continue
                }
                target = QueryContextTarget(
                    name: table.name,
                    schema: key.schema ?? table.schema,
                    kind: table.type,
                    rowCount: table.rowCount
                )
            } else {
                guard !candidate.mustMatchInventory else { continue }
                target = QueryContextTarget(name: candidate.name, schema: key.schema, kind: nil, rowCount: nil)
            }

            let identity = "\(target.schema ?? "")\u{1F}\(target.name)"
            guard seen.insert(identity).inserted else { continue }
            if targets.count < limit {
                targets.append(target)
            } else {
                notDescribed.append(candidate.written)
            }
        }
        return Matches(targets: targets, notFound: notFound, notDescribed: notDescribed)
    }

    private enum Placement {
        case inScope(schema: String?)
        case outside
    }

    private static func placement(of reference: QueryTableReference, scope: DatabaseScope, slot: EngineNamespaceSlot) -> Placement {
        let qualifiers = reference.qualifiers
        switch slot {
        case .schema:
            if qualifiers.count >= 2, !sameName(qualifiers[qualifiers.count - 2], scope.database) {
                return .outside
            }
            return .inScope(schema: qualifiers.last ?? scope.schema)
        case .database:
            guard let database = qualifiers.first else { return .inScope(schema: scope.schema) }
            return sameName(database, scope.database) ? .inScope(schema: scope.schema) : .outside
        case .unqualified:
            return .inScope(schema: scope.schema)
        }
    }

    private struct InventoryIndex {
        private var exact: [String: TableInfo] = [:]
        private var folded: [String: [TableInfo]] = [:]

        init(_ inventory: [TableInfo]) {
            for table in inventory {
                if exact[table.name] == nil {
                    exact[table.name] = table
                }
                folded[table.name.lowercased(), default: []].append(table)
            }
        }

        func table(named name: String) -> TableInfo? {
            if let match = exact[name] {
                return match
            }
            let candidates = folded[name.lowercased()] ?? []
            return candidates.count == 1 ? candidates.first : nil
        }
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
