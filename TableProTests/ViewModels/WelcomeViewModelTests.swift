//
//  WelcomeViewModelTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import XCTest

@MainActor
final class WelcomeViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var syncSuiteName: String!
    private var syncDefaults: UserDefaults!
    private var connectionFileURL: URL!
    private var groupStorage: GroupStorage!
    private var connectionStorage: ConnectionStorage!
    private var viewModel: WelcomeViewModel!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        suiteName = "com.TablePro.tests.WelcomeViewModel.\(unique)"
        syncSuiteName = "com.TablePro.tests.WelcomeViewModel.sync.\(unique)"
        guard let defaults = UserDefaults(suiteName: suiteName),
              let syncDefaults = UserDefaults(suiteName: syncSuiteName) else {
            XCTFail("Could not create isolated UserDefaults suites")
            return
        }
        self.defaults = defaults
        self.syncDefaults = syncDefaults
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncDefaults))
        connectionFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("welcome-connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: connectionFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        connectionStorage = ConnectionStorage(
            fileURL: connectionFileURL,
            userDefaults: defaults,
            syncTracker: tracker
        )
        groupStorage = GroupStorage(
            userDefaults: defaults,
            syncTracker: tracker,
            connectionStorage: self.connectionStorage
        )
        viewModel = WelcomeViewModel(services: makeServices())
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        syncDefaults.removePersistentDomain(forName: syncSuiteName)
        try? FileManager.default.removeItem(at: connectionFileURL)
        viewModel = nil
        groupStorage = nil
        connectionStorage = nil
        defaults = nil
        syncDefaults = nil
        suiteName = nil
        syncSuiteName = nil
        connectionFileURL = nil
        super.tearDown()
    }

    private func makeServices() -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: connectionStorage,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            groupStorage: groupStorage,
            tagStorage: live.tagStorage,
            sshProfileStorage: live.sshProfileStorage,
            licenseManager: live.licenseManager,
            conflictResolver: live.conflictResolver,
            syncMetadataStorage: live.syncMetadataStorage,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: live.syncTracker,
            themeEngine: live.themeEngine
        )
    }

    private func groupIds(in nodes: [ConnectionGroupTreeNode]) -> [UUID] {
        nodes.flatMap { node -> [UUID] in
            guard case .group(let group, let children) = node else { return [] }
            return [group.id] + groupIds(in: children)
        }
    }

    func testCreateGroupShowsImmediatelyInTree() throws {
        XCTAssertTrue(groupIds(in: viewModel.treeItems).isEmpty)

        viewModel.createGroup(name: "Production", color: .red, parentId: nil)

        let created = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Production" })
        XCTAssertTrue(groupIds(in: viewModel.treeItems).contains(created.id))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(created.id))
    }

    func testCreateSubgroupExpandsParentAndChild() throws {
        viewModel.createGroup(name: "Parent", color: .none, parentId: nil)
        let parentId = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Parent" }?.id)

        viewModel.createGroup(name: "Child", color: .none, parentId: parentId)
        let childId = try XCTUnwrap(groupStorage.loadGroups().first { $0.name == "Child" }?.id)

        XCTAssertTrue(groupIds(in: viewModel.treeItems).contains(parentId))
        XCTAssertTrue(groupIds(in: viewModel.treeItems).contains(childId))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(parentId))
        XCTAssertTrue(viewModel.expandedGroupIds.contains(childId))
    }

    func testCreateDuplicateNameDoesNotAddSecondNode() {
        viewModel.createGroup(name: "Staging", color: .orange, parentId: nil)
        viewModel.createGroup(name: "staging", color: .blue, parentId: nil)

        let stagingNodes = groupIds(in: viewModel.treeItems).filter { id in
            viewModel.groups.first { $0.id == id }?.name.lowercased() == "staging"
        }
        XCTAssertEqual(stagingNodes.count, 1)
    }
}
