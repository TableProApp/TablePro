import Foundation
import TableProConnectionLibrary

enum PreferenceKeys {
    static let linkedFolders = JSONDefaultsKey<[LinkedFolder]>("com.TablePro.linkedFolders")
    static let linkedSQLFolders = JSONDefaultsKey<[LinkedSQLFolder]>("com.TablePro.linkedSQLFolders")
    static let selectedSettingsPane = DefaultsKey<String>("com.TablePro.settings.selectedPane")
    static let rowInspectorFieldHeights = JSONDefaultsKey<[InspectorFieldHeightStore.Entry]>("com.TablePro.rightSidebar.fieldHeights")
    // Text or Map, as the field's picker last left it. Device-local, like the heights beside it.
    static let rowInspectorGeometryFieldMode = DefaultsKey<String>("com.TablePro.rightSidebar.geometryFieldMode")
    static let workspaceRailOrder = JSONDefaultsKey<[WorkspaceID]>("com.TablePro.workspaceRail.order")
    static let queryPlanRawFontSize = DefaultsKey<Double>("com.TablePro.queryPlan.rawFontSize")
    static let queryPlanBarMetric = DefaultsKey<String>("com.TablePro.queryPlan.barMetric")
    static let lastBackupDirectory = DefaultsKey<String>("com.TablePro.backup.lastDirectory")
    // Device-local: what What's New has shown on this Mac, so it never syncs.
    static let lastSeenAppBuild = DefaultsKey<Int>("com.TablePro.welcome.lastSeenAppBuild")
    // What a build before `lastSeenAppBuild` recorded instead, read once to carry it over.
    static let lastSeenAppVersion = DefaultsKey<String>("com.TablePro.welcome.lastSeenAppVersion")
    // Device-local: the sign-in window shows once per Mac, whatever another Mac has seen.
    static let signInPromptShown = DefaultsKey<Bool>("com.TablePro.account.signInPromptShown")
    static let connectionListSortMode = DefaultsKey<String>("com.TablePro.connectionList.sortMode")
    static let connectionListFavoritesOrder = DefaultsKey<[String]>("com.TablePro.connectionList.favoritesOrder")
    static let connectionListShowsRecent = DefaultsKey<Bool>("com.TablePro.connectionList.showsRecent")
    static let recentConnections = JSONDefaultsKey<RecentConnectionsLedger>("com.TablePro.connectionList.recentConnections")
    // Device-local, and in the standard domain so a configuration profile can pin it.
    static let receivesBetaUpdates = DefaultsKey<Bool>("com.TablePro.updates.receivesBetaUpdates")
    // Set by Relaunch to Update and cleared by the next launch, which reopens the last session once.
    static let reopenSessionAfterRelaunch = DefaultsKey<Bool>("com.TablePro.updates.reopenSessionAfterRelaunch")
    // Device-local: the highest plugin manifest serial accepted here, so an older signed manifest is refused.
    static let pluginRegistrySerial = DefaultsKey<Int>("com.TablePro.plugins.registrySerial")
    // Device-local: connections opened from a file or a link and never saved, whose state the next launch removes.
    static let transientConnectionIds = JSONDefaultsKey<[UUID]>("com.TablePro.connections.transientIds")

    static let registeredKeyNames: [String] = [
        connectionListSortMode.name,
        connectionListFavoritesOrder.name,
        connectionListShowsRecent.name,
        recentConnections.name,
        linkedFolders.name,
        linkedSQLFolders.name,
        selectedSettingsPane.name,
        rowInspectorFieldHeights.name,
        rowInspectorGeometryFieldMode.name,
        workspaceRailOrder.name,
        queryPlanRawFontSize.name,
        queryPlanBarMetric.name,
        lastBackupDirectory.name,
        lastSeenAppBuild.name,
        lastSeenAppVersion.name,
        signInPromptShown.name,
        receivesBetaUpdates.name,
        reopenSessionAfterRelaunch.name,
        pluginRegistrySerial.name,
        transientConnectionIds.name,
    ]

    static let columnDisplayFormatsPrefix = "com.TablePro.columns.displayFormat."
    static let foreignKeyLabelColumnPrefix = "com.TablePro.foreignKey.labelColumn."
    static let importColumnMappingPrefix = "com.TablePro.import.columnMapping."
    static let tableFoldersPrefix = "com.TablePro.tableFolders."
    static let rowGenerationPrefix = "com.TablePro.rowGeneration."

    static func columnDisplayFormats(_ scope: TableScope) -> JSONDefaultsKey<[String: String]> {
        JSONDefaultsKey(columnDisplayFormatsPrefix + scope.storageComponent)
    }

    static func recentTables(connectionId: UUID) -> JSONDefaultsKey<[RecentTableEntry]> {
        JSONDefaultsKey("com.TablePro.recentTables." + connectionId.uuidString)
    }

    static func foreignKeyLabelColumn(_ scope: TableScope) -> DefaultsKey<String> {
        DefaultsKey(foreignKeyLabelColumnPrefix + scope.storageComponent)
    }

    static func importColumnMapping(_ scope: TableScope) -> JSONDefaultsKey<[String: ImportMappingOverride]> {
        JSONDefaultsKey(importColumnMappingPrefix + scope.storageComponent)
    }

    static func rowGeneration(_ scope: TableScope) -> JSONDefaultsKey<RowGenerationSettings> {
        JSONDefaultsKey(rowGenerationPrefix + scope.storageComponent)
    }

    static func tableFolders(connectionId: UUID) -> JSONDefaultsKey<TableFolderStorage.Document> {
        JSONDefaultsKey(tableFoldersPrefix + connectionId.uuidString)
    }
}
