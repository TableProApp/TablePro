//
//  DatabaseTreeAttachedSchemaTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class SessionTemporaryTables: TemporaryTableSessionReading {
    private final class Session {}

    let connectionId: UUID
    let database: String
    var tables: [TableInfo] = []
    private let session = Session()

    init(connectionId: UUID, database: String) {
        self.connectionId = connectionId
        self.database = database
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        guard connectionId == self.connectionId else { return nil }
        return DatabaseScope(connectionId: connectionId, database: database, schema: nil)
    }

    func temporaryTableSession(for scope: DatabaseScope) -> ObjectIdentifier? {
        ObjectIdentifier(session)
    }

    func readTemporaryTables(in scope: DatabaseScope) async throws -> TemporaryTableListing {
        TemporaryTableListing(tables: tables, session: ObjectIdentifier(session))
    }
}

/// The flat sidebar of a SQLite connection lists each database it attached as its own row, below the
/// opened file's own sections.
@MainActor
struct DatabaseTreeAttachedSchemaTests {
    private struct Fixture {
        let connectionId: UUID
        let coordinator: DatabaseTreeOutlineCoordinator
        let viewModel: SidebarViewModel
        let scrollView: NSScrollView
    }

    private func makeFixture(
        type: DatabaseType,
        database: String,
        schemas: [String],
        connectionId: UUID? = nil,
        searchText: String = "",
        temporaryTables: TemporaryTableStore? = nil
    ) async throws -> Fixture {
        let connection = TestFixtures.makeConnection(id: connectionId ?? UUID(), database: database, type: type)
        let driver = SideObjectsMockDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.schemasToReturn = schemas
        await SchemaService.shared.load(connectionId: connection.id, driver: driver, connection: connection)

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "AttachedSchemaColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let sidebarState = SharedSidebarState.forConnection(connection.id)
        sidebarState.sidebarLayout = .flat
        let viewModel = SidebarViewModel(
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            databaseType: type,
            connectionId: connection.id
        )
        let coordinator = DatabaseTreeOutlineCoordinator(temporaryTables: temporaryTables)
        coordinator.connectionId = connection.id
        coordinator.databaseType = type
        coordinator.sidebarState = sidebarState
        coordinator.windowState = WindowSidebarState()
        coordinator.viewModel = viewModel
        coordinator.activeDatabase = database
        coordinator.showRecentTables = false
        coordinator.searchText = searchText
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        coordinator.refresh()
        return Fixture(connectionId: connection.id, coordinator: coordinator, viewModel: viewModel, scrollView: scrollView)
    }

    private func tearDown(_ fixture: Fixture) async {
        await SchemaService.shared.invalidate(connectionId: fixture.connectionId)
        SharedSidebarState.removeConnection(fixture.connectionId)
        _ = fixture.scrollView
        _ = fixture.viewModel
    }

    private func rootKinds(_ fixture: Fixture) -> [DatabaseTreeNode.Kind] {
        fixture.coordinator.resolvedChildren(of: nil).map { $0.kind }
    }

    private func attachedRows(_ fixture: Fixture) -> [String] {
        rootKinds(fixture).compactMap { kind in
            guard case .schema(_, let schema) = kind else { return nil }
            return schema
        }
    }

    @Test("SQLite and libSQL list attached databases; DuckDB browses them as databases and a schema engine switches")
    func whichEnginesListAttachedDatabases() {
        #expect(PluginManager.shared.listsAttachedDatabases(for: .sqlite))
        #expect(PluginManager.shared.listsAttachedDatabases(for: .libsql))
        #expect(!PluginManager.shared.listsAttachedDatabases(for: .duckdb))
        #expect(!PluginManager.shared.listsAttachedDatabases(for: .postgresql))
        #expect(!PluginManager.shared.listsAttachedDatabases(for: .mysql))
    }

    @Test("Each attached database is a row of its own, in attach order, after the opened file's sections")
    func listsAttachedDatabases() async throws {
        let fixture = try await makeFixture(type: .sqlite, database: "/data/app.db", schemas: ["auth", "audit"])

        let kinds = rootKinds(fixture)
        #expect(attachedRows(fixture) == ["auth", "audit"])
        let firstSection = kinds.firstIndex { if case .objectKindSection = $0 { return true } else { return false } }
        let firstAttached = kinds.firstIndex { if case .schema = $0 { return true } else { return false } }
        let sectionIndex = try #require(firstSection)
        let attachedIndex = try #require(firstAttached)
        #expect(sectionIndex < attachedIndex)
        #expect(SchemaService.shared.schemas(for: fixture.connectionId).isEmpty)
        await tearDown(fixture)
    }

    @Test("A temporary table lists in the Temporary section and the attached databases as their own rows")
    func temporaryTableAndAttachedDatabasesListApart() async throws {
        let connectionId = UUID()
        let reader = SessionTemporaryTables(connectionId: connectionId, database: "/data/app.db")
        reader.tables = [TableInfo(name: "users", type: .table, rowCount: nil, isTemporary: true)]
        let store = TemporaryTableStore(reader: { reader })
        let fixture = try await makeFixture(
            type: .sqlite, database: "/data/app.db", schemas: ["auth"], connectionId: connectionId,
            temporaryTables: store
        )
        store.refresh(connectionId: connectionId)
        await store.waitUntilIdle(connectionId: connectionId)
        fixture.coordinator.refresh()

        let kinds = rootKinds(fixture)
        #expect(attachedRows(fixture) == ["auth"])
        let firstTemporary = kinds.firstIndex { if case .temporarySection = $0 { return true } else { return false } }
        let firstAttached = kinds.firstIndex { if case .schema = $0 { return true } else { return false } }
        let temporaryIndex = try #require(firstTemporary)
        let attachedIndex = try #require(firstAttached)
        #expect(temporaryIndex < attachedIndex)

        let sectionNode = fixture.coordinator.resolvedChildren(of: nil).first {
            if case .temporarySection = $0.kind { return true } else { return false }
        }
        let section = try #require(sectionNode)
        let temporaryRefs = fixture.coordinator.resolvedChildren(of: section).compactMap { node -> DatabaseTreeTableRef? in
            guard case .temporaryTable(let ref) = node.kind else { return nil }
            return ref
        }
        #expect(temporaryRefs.map { $0.table.name } == ["users"])
        #expect(temporaryRefs.allSatisfy { $0.schema == nil && !$0.isInAttachedDatabase(of: .sqlite) })
        await tearDown(fixture)
    }

    @Test("A search keeps an attached database whose name matches and drops one with nothing loaded to match")
    func searchFiltersAttachedDatabases() async throws {
        let fixture = try await makeFixture(
            type: .sqlite, database: "/data/app.db", schemas: ["auth", "audit"], searchText: "aud"
        )
        #expect(attachedRows(fixture) == ["audit"])
        await tearDown(fixture)
    }

    @Test("An engine whose schemas are switched lists none of them as attached rows")
    func schemaEngineListsNoAttachedRows() async throws {
        let fixture = try await makeFixture(type: .postgresql, database: "shop", schemas: ["public", "billing"])
        #expect(attachedRows(fixture).isEmpty)
        #expect(SchemaService.shared.attachedSchemas(for: fixture.connectionId).isEmpty)
        await tearDown(fixture)
    }

    @Test("A key between two tables of an attached database leads back into that database, and a main key stays put")
    func foreignKeysStayInTheAttachedDatabase() {
        let connectionId = UUID()
        #expect(EngineNamespaceSlot(databaseType: .sqlite) == .schema)
        let attachedOrigin = DatabaseScope(connectionId: connectionId, database: "/data/app.db", schema: "auth")
        let target = ForeignKeyTargetScope.resolve(
            origin: attachedOrigin, referencedSchema: "auth", databaseType: .sqlite
        )
        #expect(target == attachedOrigin)

        let mainOrigin = DatabaseScope(connectionId: connectionId, database: "/data/app.db", schema: nil)
        #expect(ForeignKeyTargetScope.resolve(origin: mainOrigin, referencedSchema: nil, databaseType: .sqlite) == mainOrigin)
    }

    @Test("Without a search every attached database shows; the filter only narrows a running search")
    func visibleWithoutSearch() {
        #expect(SidebarAttachedSchemas.visible(
            attached: ["auth", "audit"], database: "/data/app.db", searchText: "", loadedContent: { _ in nil }
        ) == ["auth", "audit"])
        #expect(SidebarAttachedSchemas.visible(
            attached: ["auth", "audit"], database: "/data/app.db", searchText: "zzz", loadedContent: { _ in nil }
        ).isEmpty)
    }
}
