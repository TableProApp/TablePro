//
//  AIChatAlwaysAllowTests.swift
//  TableProTests
//

import Foundation
import TableProMCP
import TableProSyncTransport
@testable import TablePro
import Testing

@MainActor
struct AIChatAlwaysAllowTests {
    private struct WriterTool: ChatTool {
        let name = "writer"
        let description = ""
        let inputSchema: JsonValue = .object(["type": .string("object")])
        let mode: ChatToolMode = .write

        func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
            ChatToolResult(content: "1 row changed", isError: false)
        }
    }

    private let pool = EphemeralDefaultsPool()
    private let storage: ConnectionStorage
    private let registry: ChatToolRegistry

    init() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("always-allow-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: try pool.make().defaults))
        storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: try pool.make().defaults,
            syncTracker: tracker,
            appEvents: AppEvents()
        )
        registry = ChatToolRegistry()
        registry.register(WriterTool())
    }

    private func viewModel(holding connection: DatabaseConnection) -> AIChatViewModel {
        let viewModel = AIChatViewModel(services: services())
        viewModel.connection = connection
        return viewModel
    }

    private func stored(alwaysAllowed tools: Set<String>) throws -> DatabaseConnection {
        let connection = DatabaseConnection(name: "Staging", safeModeLevel: .alert, aiAlwaysAllowedTools: tools)
        try #require(storage.saveConnections([connection]))
        return connection
    }

    @Test("A tool forgotten in storage asks again while the pane stays open")
    func forgottenToolAsksAgain() throws {
        var paneCopy = try stored(alwaysAllowed: [])
        paneCopy.aiAlwaysAllowedTools = ["writer"]

        let state = viewModel(holding: paneCopy).computeInitialApprovalState(for: "writer", registry: registry)

        #expect(state == .pending)
    }

    @Test("A grant that reached storage after the pane opened skips the card")
    func grantInStorageSkipsTheCard() throws {
        var paneCopy = try stored(alwaysAllowed: ["writer"])
        paneCopy.aiAlwaysAllowedTools = []

        let state = viewModel(holding: paneCopy).computeInitialApprovalState(for: "writer", registry: registry)

        #expect(state == .approved)
    }

    @Test("A connection with no stored record keeps the pane's own grants")
    func unsavedConnectionUsesThePaneCopy() {
        let unsaved = DatabaseConnection(name: "Scratch", safeModeLevel: .alert, aiAlwaysAllowedTools: ["writer"])

        let state = viewModel(holding: unsaved).computeInitialApprovalState(for: "writer", registry: registry)

        #expect(state == .approved)
    }

    @Test("Always Allow after a revoke is stored again")
    func alwaysAllowAfterARevokeIsStored() throws {
        var paneCopy = try stored(alwaysAllowed: [])
        paneCopy.aiAlwaysAllowedTools = ["writer"]

        viewModel(holding: paneCopy).persistAlwaysAllowed(toolName: "writer")

        #expect(storage.loadConnection(id: paneCopy.id)?.aiAlwaysAllowedTools == ["writer"])
    }

    private func services() -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: storage,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
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
            featureAccess: live.featureAccess,
            syncMetadataStorage: live.syncMetadataStorage,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: live.syncTracker,
            welcomeRouter: live.welcomeRouter,
            telemetry: live.telemetry
        )
    }
}
