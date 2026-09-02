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

    static let registeredKeyNames: [String] = [
        linkedFolders.name,
        linkedSQLFolders.name,
        selectedSettingsPane.name,
        rowInspectorJsonFieldHeight.name,
        rowInspectorTextFieldHeight.name,
        workspaceRailOrder.name,
        queryPlanRawFontSize.name,
    ]

    static func columnDisplayFormats(_ scope: TableScope) -> DefaultsKey<[String: ValueDisplayFormat]> {
        DefaultsKey("com.TablePro.columns.displayFormat." + scope.storageComponent)
    }

    static func recentTables(connectionId: UUID) -> DefaultsKey<[RecentTableEntry]> {
        DefaultsKey("com.TablePro.recentTables." + connectionId.uuidString)
    }

    static func foreignKeyLabelColumn(_ scope: TableScope) -> DefaultsKey<String> {
        DefaultsKey("com.TablePro.foreignKey.labelColumn." + scope.storageComponent)
    }
}
