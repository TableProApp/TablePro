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

    static let registeredKeyNames: [String] = [
        linkedFolders.name,
        linkedSQLFolders.name,
        selectedSettingsPane.name,
        rowInspectorJsonFieldHeight.name,
        rowInspectorTextFieldHeight.name,
        workspaceRailOrder.name,
        queryPlanRawFontSize.name,
        queryPlanBarMetric.name,
        lastBackupDirectory.name,
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
