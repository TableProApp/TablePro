//
//  PreferenceKeys.swift
//  TablePro
//

import Foundation

enum PreferenceKeys {
    static let linkedFolders = DefaultsKey<[LinkedFolder]>("com.TablePro.linkedFolders")
    static let linkedSQLFolders = DefaultsKey<[LinkedSQLFolder]>("com.TablePro.linkedSQLFolders")
    static let selectedSettingsPane = DefaultsKey<String>("com.TablePro.settings.selectedPane")
    static let rowInspectorJsonFieldHeight = DefaultsKey<Double>("com.TablePro.rightSidebar.jsonFieldHeight")
    static let rowInspectorTextFieldHeight = DefaultsKey<Double>("com.TablePro.rightSidebar.textFieldHeight")
    static let workspaceRailOrder = DefaultsKey<[WorkspaceID]>("com.TablePro.workspaceRail.order")
    static let queryPlanRawFontSize = DefaultsKey<Double>("com.TablePro.queryPlan.rawFontSize")
    static let queryPlanBarMetric = DefaultsKey<String>("com.TablePro.queryPlan.barMetric")
    static let lastBackupDirectory = DefaultsKey<String>("com.TablePro.backup.lastDirectory")
    /// The app version this Mac last showed the welcome window for. Device-local: it records what
    /// has been shown here, not a preference, so it must not sync to another Mac that has not.
    static let lastSeenAppVersion = DefaultsKey<String>("com.TablePro.welcome.lastSeenAppVersion")
    static let connectionListSortMode = DefaultsKey<String>("com.TablePro.connectionList.sortMode")
    static let connectionListFavoritesOrder = DefaultsKey<[String]>("com.TablePro.connectionList.favoritesOrder")
    static let recentConnections = DefaultsKey<Data>("com.TablePro.connectionList.recentConnections")

    static let registeredKeyNames: [String] = [
        connectionListSortMode.name,
        connectionListFavoritesOrder.name,
        recentConnections.name,
        linkedFolders.name,
        linkedSQLFolders.name,
        selectedSettingsPane.name,
        rowInspectorJsonFieldHeight.name,
        rowInspectorTextFieldHeight.name,
        workspaceRailOrder.name,
        queryPlanRawFontSize.name,
        queryPlanBarMetric.name,
        lastBackupDirectory.name,
        lastSeenAppVersion.name,
    ]

    static let columnDisplayFormatsPrefix = "com.TablePro.columns.displayFormat."
    static let foreignKeyLabelColumnPrefix = "com.TablePro.foreignKey.labelColumn."

    static func columnDisplayFormats(_ scope: TableScope) -> DefaultsKey<[String: ValueDisplayFormat]> {
        DefaultsKey(columnDisplayFormatsPrefix + scope.storageComponent)
    }

    static func recentTables(connectionId: UUID) -> DefaultsKey<[RecentTableEntry]> {
        DefaultsKey("com.TablePro.recentTables." + connectionId.uuidString)
    }

    static func foreignKeyLabelColumn(_ scope: TableScope) -> DefaultsKey<String> {
        DefaultsKey(foreignKeyLabelColumnPrefix + scope.storageComponent)
    }
}
