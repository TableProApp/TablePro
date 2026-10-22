//
//  JoinBuilderViewModel.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

internal struct JoinBuilderLaunchRequest: Identifiable, Equatable, Sendable {
    internal let id: UUID
    internal let database: String
    internal let schema: String?
    internal let tables: [String]

    internal init(id: UUID = UUID(), database: String, schema: String?, tables: [String]) {
        self.id = id
        self.database = database
        self.schema = schema?.nilIfEmpty
        self.tables = tables
    }
}

internal enum JoinBuilderEligibility {
    internal static func supportsJoinBuilder(
        editorLanguage: EditorLanguage,
        dialect: SQLDialectDescriptor?,
        supportsForeignKeys: Bool
    ) -> Bool {
        editorLanguage == .sql && dialect != nil && supportsForeignKeys
    }

    @MainActor
    internal static func supportsJoinBuilder(_ databaseType: DatabaseType) -> Bool {
        supportsJoinBuilder(
            editorLanguage: PluginManager.shared.editorLanguage(for: databaseType),
            dialect: try? resolveSQLDialect(for: databaseType),
            supportsForeignKeys: databaseType.supportsForeignKeys
        )
    }
}

@MainActor
internal final class JoinBuilderViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "JoinBuilder")

    internal enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    internal struct Catalog {
        let graph: JoinGraph
        let columnTypes: [String: [String: ColumnType]]
    }

    internal let launch: JoinBuilderLaunchRequest
    internal let connection: DatabaseConnection

    @Published internal private(set) var loadState: LoadState = .loading
    @Published internal private(set) var graph: JoinGraph = .empty
    @Published internal private(set) var draft = JoinQueryDraft()
    @Published internal var tableFilter = ""

    private var columnTypes: [String: [String: ColumnType]] = [:]
    private var qualifyingSchema: String?
    private let services: AppServices

    internal init(launch: JoinBuilderLaunchRequest, connection: DatabaseConnection, services: AppServices = .live) {
        self.launch = launch
        self.connection = connection
        self.services = services
    }

    internal var scopeDescription: String {
        DatabaseEndpoint.from(
            connection: connection,
            database: launch.database,
            schema: launch.schema ?? scope?.schema
        ).qualifiedDescription
    }

    internal var filteredTables: [String] {
        let term = tableFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return graph.tableNames }
        return graph.tableNames.filter { $0.localizedCaseInsensitiveContains(term) || draft.contains($0) }
    }

    internal var sql: String? {
        guard let dialect = try? resolveSQLDialect(for: connection.type) else { return nil }
        return JoinQuerySQLWriter(
            graph: graph,
            columnTypes: columnTypes,
            dialect: dialect,
            databaseType: connection.type,
            schema: qualifyingSchema,
            quote: quoteIdentifier(dialect: dialect)
        ).sql(for: draft)
    }

    internal var filterableColumns: [JoinColumnRef] {
        draft.tables.flatMap { table in
            graph.columns(of: table.name).map { JoinColumnRef(table: table.name, column: $0) }
        }
    }

    internal var crossJoinedTables: [String] {
        draft.tables.dropFirst().filter { $0.condition == nil }.map(\.name)
    }

    private var scope: DatabaseScope? {
        services.databaseManager.resolvedScope(database: launch.database, schema: launch.schema, for: connection.id)
    }

    // MARK: - Loading

    internal func loadIfNeeded() async {
        guard loadState != .loaded else { return }
        await load()
    }

    internal func load() async {
        guard let scope else {
            loadState = .failed(String(localized: "No database connection"))
            return
        }
        if graph.columnsByTable.isEmpty {
            loadState = .loading
        }
        do {
            let catalog = try await fetchCatalog(scope: scope)
            adopt(catalog, scope: scope)
        } catch {
            Self.logger.error("Failed to read the join builder catalog: \(error.publicLogShape, privacy: .public)")
            if graph.columnsByTable.isEmpty {
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    internal func adopt(_ catalog: Catalog, scope: DatabaseScope) {
        graph = catalog.graph
        columnTypes = catalog.columnTypes
        // Picking a schema in the sidebar does not move SQL Server's name resolution, so qualify as browsing does.
        qualifyingSchema = SchemaQualifiedName.explicitSchema(scope.schema, databaseType: connection.type)
        var seeded = JoinQueryDraft()
        for table in launch.tables {
            seeded.add(table, in: graph)
        }
        draft = seeded
        loadState = .loaded
    }

    private func fetchCatalog(scope: DatabaseScope) async throws -> Catalog {
        let (columns, foreignKeys) = try await services.databaseManager.withMetadataDriver(
            scope: scope, workload: .bulk
        ) { driver in
            let columns = try await driver.fetchAllColumns()
            let foreignKeys = try await driver.fetchAllForeignKeys()
            return (columns, foreignKeys)
        }
        let slot = EngineNamespaceSlot(databaseType: connection.type)
        let graph = JoinGraph(
            columns: columns.mapValues { $0.map(\.name) },
            foreignKeys: foreignKeys,
            isLocal: { key in
                ForeignKeyTargetScope.pointsWithin(
                    scope, referencedDatabase: key.referencedDatabase, referencedSchema: key.referencedSchema, slot: slot
                )
            }
        )
        let classifier = ColumnTypeClassifier(family: SQLTypeFamily.of(connection.type))
        let types = columns.mapValues { infos in
            Dictionary(
                infos.map { ($0.name, classifier.classify(rawTypeName: $0.typeNameForClassification)) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return Catalog(graph: graph, columnTypes: types)
    }

    private func quoteIdentifier(dialect: SQLDialectDescriptor) -> (String) -> String {
        guard let driver = services.databaseManager.driver(for: connection.id) else {
            return quoteIdentifierFromDialect(dialect)
        }
        return { driver.quoteIdentifier($0) }
    }

    // MARK: - Editing

    internal func isIncluded(_ table: String) -> Bool {
        draft.contains(table)
    }

    internal func setIncluded(_ isIncluded: Bool, table: String) {
        if isIncluded {
            draft.add(table, in: graph)
        } else {
            draft.remove(table, in: graph)
        }
    }

    internal func candidates(forTableAt index: Int) -> [JoinRelationship] {
        draft.candidates(forTableAt: index, in: graph)
    }

    internal func setCondition(_ condition: JoinRelationship?, forTableAt index: Int) {
        draft.setCondition(condition, forTableAt: index, in: graph)
    }

    internal func setKind(_ kind: JoinKind, forTableAt index: Int) {
        draft.setKind(kind, forTableAt: index)
    }

    internal func isSelected(_ column: JoinColumnRef) -> Bool {
        draft.isSelected(column)
    }

    internal func setSelected(_ isSelected: Bool, column: JoinColumnRef) {
        draft.setSelected(isSelected, column: column, in: graph)
    }

    internal func addFilter() {
        guard let column = filterableColumns.first else { return }
        draft.filters.append(JoinFilter(column: column))
    }

    internal func removeFilter(_ id: UUID) {
        draft.filters.removeAll { $0.id == id }
    }

    // Applied to the stored filter, never to the copy a row was drawn from.
    internal func updateFilter(_ id: UUID, _ change: (inout JoinFilter) -> Void) {
        guard let index = draft.filters.firstIndex(where: { $0.id == id }) else { return }
        change(&draft.filters[index])
    }

    internal func conditionTitle(_ relationship: JoinRelationship) -> String {
        relationship.columnPairs
            .map { "\(relationship.childTable).\($0.child) = \(relationship.parentTable).\($0.parent)" }
            .joined(separator: " AND ")
    }
}
