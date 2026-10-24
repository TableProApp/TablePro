//
//  AIChatTableMentionsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct AIChatTableMentionsTests {
    private static let names = [
        "orders", "Order_Items", "reorder_log", "customers", "ORDER_LOG",
        "Café", "Cafe\u{301}_menu", "Đ_bảng", "audit_log", "products", "table10", "table2",
        "weiß_log", "İstanbul", "kiss_list"
    ]

    private static func index(_ names: [String]) -> TableMentionIndex {
        TableMentionIndex(tables: names.map { TestFixtures.makeTableInfo(name: $0) })
    }

    // What the composer ran over every table on each keystroke before the index.
    private static func filterSortAndCut(_ names: [String], query: String, limit: Int) -> [String] {
        Array(
            names
                .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .prefix(limit)
        )
    }

    @Test("Names are kept in Finder order")
    func namesAreSorted() {
        #expect(Self.index(["table10", "Table2", "accounts"]).names == ["accounts", "Table2", "table10"])
    }

    @Test(
        "A query finds the names the per-keystroke filter found, in the same order",
        arguments: ["", "o", "ORD", "_log", "café", "CAFÉ", "đ", "table", "zzz", "weis", "ss", "i", "İ"]
    )
    func matchesThePerKeystrokeFilter(query: String) {
        #expect(
            Self.index(Self.names).names(matching: query, limit: 5)
                == Self.filterSortAndCut(Self.names, query: query, limit: 5)
        )
    }

    @Test("A name two schemas share is offered once")
    func sharedNameIsOfferedOnce() {
        let index = TableMentionIndex(tables: [
            TestFixtures.makeTableInfo(name: "orders", schema: "sales"),
            TestFixtures.makeTableInfo(name: "orders", schema: "archive")
        ])
        #expect(index.names == ["orders"])
    }

    @Test("The Tables menu lists the first names in order and leaves the rest to @")
    func tablesMenuIsCapped() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let count = AIChatViewModel.mentionMenuTableLimit + 20
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: AIChatSchemaFixture.names(count: count))
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection

        vm.trackTableMentions()
        await vm.tableMentionBuild?.value

        let expected = Array(AIChatSchemaFixture.names(count: count).prefix(AIChatViewModel.mentionMenuTableLimit))
        #expect(vm.mentionMenuTableNames == expected)
        #expect(vm.hasUnlistedMentionTables)
        #expect(vm.tableMentions.names(matching: "_119", limit: 5) == ["table_119"])
    }

    @Test("The index is rebuilt when a reload changes the catalog")
    func indexFollowsCatalogReload() async throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let fixture = await AIChatSchemaFixture.loaded(connection: connection, names: ["orders"])
        let vm = AIChatViewModel(services: fixture.services)
        vm.connection = connection
        vm.trackTableMentions()
        await vm.tableMentionBuild?.value
        #expect(vm.tableMentions.names == ["orders"])

        fixture.driver.tablesToReturn = ["invoices", "accounts"].map { TestFixtures.makeTableInfo(name: $0) }
        await fixture.schemaService.reload(connectionId: connection.id, driver: fixture.driver, connection: connection)

        try await waitUntil { vm.tableMentions.names == ["accounts", "invoices"] }
        #expect(!vm.hasUnlistedMentionTables)
    }
}

@MainActor
struct AIChatSchemaFixture {
    let schemaService: SchemaService
    let driver: MockDatabaseDriver
    let services: AppServices

    static func names(count: Int) -> [String] {
        (0..<count).map { String(format: "table_%03d", $0) }
    }

    // Loaded in reverse, so a list that comes out in order was sorted.
    static func loaded(connection: DatabaseConnection, names: [String]) async -> AIChatSchemaFixture {
        let schemaService = SchemaService()
        let driver = MockDatabaseDriver(connection: connection)
        driver.tablesToReturn = names.reversed().map { TestFixtures.makeTableInfo(name: $0) }
        await schemaService.load(connectionId: connection.id, driver: driver, connection: connection)
        return AIChatSchemaFixture(schemaService: schemaService, driver: driver, services: services(schemaService: schemaService))
    }

    private static func services(schemaService: SchemaService) -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: live.connectionStorage,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
            tableFolderStorage: live.tableFolderStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            aiAccessApprovals: live.aiAccessApprovals,
            groupStorage: live.groupStorage,
            tagStorage: live.tagStorage,
            sshProfileStorage: live.sshProfileStorage,
            credentialProfileStorage: live.credentialProfileStorage,
            licenseManager: live.licenseManager,
            syncMetadataStorage: live.syncMetadataStorage,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: live.syncTracker,
            welcomeRouter: live.welcomeRouter
        )
    }
}
